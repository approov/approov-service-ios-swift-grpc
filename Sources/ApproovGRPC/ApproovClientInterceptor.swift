// ApproovService for integrating Approov into apps using GRPC.
//
// MIT License
//
// Copyright (c) 2016-present, Critical Blue Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Approov
import Foundation
import GRPC
import NIO

public class ApproovClientInterceptor<Request, Reply>: ClientInterceptor<Request, Reply> {

    // hostname/domain for which to add an Approov token to every GRPC request
    private let hostname: String

    public init(hostname: String) {
        self.hostname = hostname
    }

    public override func send(
        _ part: GRPCClientRequestPart<Request>,
        promise: EventLoopPromise<Void>?,
        context: ClientInterceptorContext<Request, Reply>
    ) {
        switch part {
        // The (user-provided) request headers, these are sent at the start of each RPC.
        case var .metadata(headers):
            // Check if Bind Header is set to a non empty string
            if ApproovService.bindHeader != "" {
                /*  Query the URLSessionConfiguration for user set headers. They would be set like so:
                 *  config.httpAdditionalHeaders = ["Authorization Bearer" : "token"]
                 *  Since the URLSessionConfiguration is part of the init call and we store its reference
                 *  we check for the presence of a user set header there.
                 */
                if let aValue = headers.first(name: ApproovService.bindHeader) {
                    // Add the Bind Header as a data hash to Approov token
                    Approov.setDataHashInToken(aValue)
                }
            }
            // Fetch the Approov token
            let result: ApproovTokenFetchResult = Approov.fetchTokenAndWait(hostname)
            print("Approov: Approov token for host: \(hostname) : \(result.loggableToken())")
            if result.isConfigChanged {
                // Store dynamic config file if a change has occurred
                if let newConfig = Approov.fetchConfig() {
                    ApproovService.storeDynamicConfig(newConfig: newConfig)
                }
            }
            switch result.status {
            case ApproovTokenFetchStatus.success:
                // Can go ahead and make the API call with the provided request object
                // Set Approov-Token header
                headers.add(name: ApproovService.approovTokenHeaderAndPrefix.approovTokenHeader,
                            value: ApproovService.approovTokenHeaderAndPrefix.approovTokenPrefix + result.token)
                // Forward the request part to the next interceptor.
                context.send(.metadata(headers), promise: promise)
            case ApproovTokenFetchStatus.noNetwork,
                 ApproovTokenFetchStatus.poorNetwork,
                 ApproovTokenFetchStatus.mitmDetected:
                // Must not proceed with the network request - cancel it
                context.cancel(promise: promise)
            case ApproovTokenFetchStatus.unprotectedURL,
                 ApproovTokenFetchStatus.unknownURL,
                 ApproovTokenFetchStatus.noApproovService:
                // We do NOT add the Approov-Token header to the request headers and proceed
                // Forward the request part to the next interceptor.
                context.send(part, promise: promise)
            default:
                context.cancel(promise: promise)
            }

        // The request message and metadata (ignored here). For unary and server-streaming RPCs we
        // expect exactly one message, for client-streaming and bidirectional streaming RPCs any number
        // of messages is permitted.
        case .message:
            // Forward the request part to the next interceptor.
            context.send(part, promise: promise)

        // The end of the request stream: must be sent exactly once, after which no more messages may
        // be sent.
        case .end:
            // Forward the request part to the next interceptor.
            context.send(part, promise: promise)
        }
    }

}
