/*
The MIT License (MIT)

Copyright (c) 2015 Cameron Pulsford

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/

import Foundation

public class TCPClient: NSObject, NSStreamDelegate {

    public weak var delegate: TCPClientDelegate?
    lazy public var delegateQueue = dispatch_get_main_queue()
    public private(set) var url: NSURL
    public private(set) var configuration: TCPClientConfiguration
    public private(set) var open = false
    public var secure = false
    public var allowInvalidCertificates = false
    lazy private var workQueue = dispatch_queue_create("com.smd.tcp.tcpClientQueue", DISPATCH_QUEUE_SERIAL)

    var inputStream: NSInputStream!
    var outputStream: NSOutputStream!
    var writers = [Writer]()

    private var opensCompleted = 0

    public init(url: NSURL, configuration: TCPClientConfiguration) {
        self.url = url
        self.configuration = configuration
    }

    public func connect() -> Bool {
        objc_sync_enter(self)
        
        var success = false

        if !open && createStreams() && configureStreams() {
            prepareForOpenStreams()
            openStreams()
            success = true
            open = true
        }

        if !success {
            disconnect()
        }

        objc_sync_exit(self)

        return success
    }

    public func disconnect() {
        objc_sync_enter(self)

        if open {
            open = false
            
            dispatch_async(workQueue) {
                self.inputStream.delegate = nil
                self.outputStream.delegate = nil
                self.inputStream.close()
                self.outputStream.close()
                self.inputStream = nil
                self.outputStream = nil
                self.open = false
                self.writers.removeAll(keepCapacity: false)
            }
        }

        objc_sync_exit(self)
    }

    // MARK: Writing

    public func write(writer: Writer) {
        dispatch_async(workQueue) {
            self.writers.append(writer)

            if self.open {
                self.write()
            }
        }
    }

    public func write(data: NSData) {
        write(DataWriter(data: data))
    }

    public func write(data: NSData, delimiter: LineDelimiter) {
        write(DataWriter(data: data, delimiter: delimiter))
    }

    // MARK: NSStreamDelegate methods

    public func stream(aStream: NSStream, handleEvent eventCode: NSStreamEvent) {
        switch eventCode {
        case NSStreamEvent.OpenCompleted:
            opensCompleted++

            if opensCompleted == 2 {
                didConnect()
            }
        case NSStreamEvent.HasBytesAvailable:
            dispatch_async(workQueue) {
                self.read()
            }
        case NSStreamEvent.HasSpaceAvailable:
            writeInBackground()
        case NSStreamEvent.ErrorOccurred:
            fallthrough
        case NSStreamEvent.EndEncountered:
            let error = aStream.streamError
            disconnectWithError(error)
        default:
            break
        }
    }

    // MARK: Methods to subclass

    public func host() -> String {
        return url.host!
    }

    public func port() -> Int {
        var port: Int = 0

        if let p = url.port {
            port = p.integerValue
        } else if let scheme = url.scheme {
            switch scheme {
            case "http":
                port = 80
            case "https":
                port = 443
            default:
                break
            }
        }

        return port
    }

    public func didConnect() {
        dispatch_async(delegateQueue) {
            var _ = self.delegate?.tcpClientDidConnect?(self)
        }

        writeInBackground()
    }

    public func didDisconnectWithError(error: NSError?) {
        dispatch_async(delegateQueue) {
            var _ = self.delegate?.tcpClientDidDisconnectWithError?(self, streamError: error)
        }
    }

    public func configureStreams() -> Bool {
        if secure {
            outputStream.setProperty(kCFStreamSocketSecurityLevelNegotiatedSSL, forKey: kCFStreamPropertySocketSecurityLevel)

            var sslOptions = [String:AnyObject]()

            if allowInvalidCertificates {
                sslOptions[kCFStreamSSLValidatesCertificateChain as String] = false
            }

            outputStream.setProperty(sslOptions, forKey: kCFStreamPropertySSLSettings)
        }

        return true
    }

    public func prepareForOpenStreams() {
        configuration.reader.client = self
        configuration.reader.prepare()
        opensCompleted = 0
        writers.removeAll(keepCapacity: false)
    }

    // MARK: Private

    private func disconnectWithError(error: NSError?) {
        disconnect()
        didDisconnectWithError(error)
    }

    private func createStreams() -> Bool {
        var iStream: NSInputStream?
        var oStream: NSOutputStream?
        NSStream.getStreamsToHostWithName(host(), port: port(), inputStream: &iStream, outputStream: &oStream)

        if iStream != nil && oStream != nil {
            inputStream = iStream!
            outputStream = oStream!
            inputStream.delegate = self
            outputStream.delegate = self
            return true
        } else {
            return false
        }
    }

    private func openStreams() {
        let runLoop = NSRunLoop.currentRunLoop()
        let mode = NSDefaultRunLoopMode
        inputStream.scheduleInRunLoop(runLoop, forMode: mode)
        outputStream.scheduleInRunLoop(runLoop, forMode: mode)
        inputStream.open()
        outputStream.open()
    }

    private func read() {
        var buffer = [UInt8](count: configuration.readSize, repeatedValue: 0)

        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(&buffer, maxLength: configuration.readSize)
            configuration.reader.handleData(NSData(bytes: &buffer, length: bytesRead))
        }
    }

    private func writeInBackground() {
        dispatch_async(workQueue) {
            self.write()
        }
    }

    private func write() {
        while self.open && self.writers.count > 0 && self.outputStream.hasSpaceAvailable {
            let writer = self.writers[0]
            let (complete, error) = writer.writeToStream(self.outputStream)

            if complete {
                self.writers.removeAtIndex(0)
            }

            if let e = error {
                self.disconnectWithError(e)
                break
            }
        }
    }

}
