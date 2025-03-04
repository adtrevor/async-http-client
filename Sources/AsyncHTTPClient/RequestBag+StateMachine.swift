//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.URL
import NIO
import NIOHTTP1

extension RequestBag {
    struct StateMachine {
        fileprivate enum State {
            case initialized
            case queued(HTTPRequestScheduler)
            case executing(HTTPRequestExecutor, RequestStreamState, ResponseStreamState)
            case finished(error: Error?)
            case redirected(HTTPResponseHead, URL)
            case modifying
        }

        fileprivate enum RequestStreamState {
            case initialized
            case producing
            case paused(EventLoopPromise<Void>?)
            case finished
        }

        fileprivate enum ResponseStreamState {
            enum Next {
                case askExecutorForMore
                case error(Error)
                case eof
            }

            case initialized
            case buffering(CircularBuffer<ByteBuffer>, next: Next)
            case waitingForRemote
        }

        private var state: State = .initialized
        private let redirectHandler: RedirectHandler<Delegate.Response>?

        init(redirectHandler: RedirectHandler<Delegate.Response>?) {
            self.redirectHandler = redirectHandler
        }
    }
}

extension RequestBag.StateMachine {
    mutating func requestWasQueued(_ scheduler: HTTPRequestScheduler) {
        guard case .initialized = self.state else {
            // There might be a race between `requestWasQueued` and `willExecuteRequest`:
            //
            // If the request is created and passed to the HTTPClient on thread A, it will move into
            // the connection pool lock in thread A. If no connection is available, thread A will
            // add the request to the waiters and leave the connection pool lock.
            // `requestWasQueued` will be called outside the connection pool lock on thread A.
            // However if thread B has a connection that becomes available and thread B enters the
            // connection pool lock directly after thread A, the request will be immediately
            // scheduled for execution on thread B. After the thread B has left the lock it will
            // call `willExecuteRequest` directly after.
            //
            // Having an order in the connection pool lock, does not guarantee an order in calling:
            // `requestWasQueued` and `willExecuteRequest`.
            //
            // For this reason we must check the state here... If we are not `.initialized`, we are
            // already executing.
            return
        }

        self.state = .queued(scheduler)
    }

    mutating func willExecuteRequest(_ executor: HTTPRequestExecutor) -> Bool {
        switch self.state {
        case .initialized, .queued:
            self.state = .executing(executor, .initialized, .initialized)
            return true
        case .finished(error: .some):
            return false
        case .executing, .redirected, .finished(error: .none), .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum ResumeProducingAction {
        case startWriter
        case succeedBackpressurePromise(EventLoopPromise<Void>?)
        case none
    }

    mutating func resumeRequestBodyStream() -> ResumeProducingAction {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("A request stream can only be resumed, if the request was started")

        case .executing(let executor, .initialized, .initialized):
            self.state = .executing(executor, .producing, .initialized)
            return .startWriter

        case .executing(_, .producing, _):
            preconditionFailure("Expected that resume is only called when if we were paused before")

        case .executing(let executor, .paused(let promise), let responseState):
            self.state = .executing(executor, .producing, responseState)
            return .succeedBackpressurePromise(promise)

        case .executing(_, .finished, _):
            // the channels writability changed to writable after we have forwarded all the
            // request bytes. Can be ignored.
            return .none

        case .executing(_, .initialized, .buffering), .executing(_, .initialized, .waitingForRemote):
            preconditionFailure("Invalid states: Response can not be received before request")

        case .redirected:
            // if we are redirected, we should cancel our request body stream anyway
            return .none

        case .finished:
            preconditionFailure("Invalid state")

        case .modifying:
            preconditionFailure("Invalid state")
        }
    }

    mutating func pauseRequestBodyStream() {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("A request stream can only be paused, if the request was started")
        case .executing(let executor, let requestState, let responseState):
            switch requestState {
            case .initialized:
                preconditionFailure("Request stream must be started before it can be paused")
            case .producing:
                self.state = .executing(executor, .paused(nil), responseState)
            case .paused:
                preconditionFailure("Expected that pause is only called when if we were producing before")
            case .finished:
                // the channels writability changed to not writable after we have forwarded the
                // last bytes from our side.
                break
            }
        case .redirected:
            // if we are redirected, we should cancel our request body stream anyway
            break
        case .finished:
            // the request is already finished nothing further to do
            break
        case .modifying:
            preconditionFailure("Invalid state")
        }
    }

    enum WriteAction {
        case write(IOData, HTTPRequestExecutor, EventLoopFuture<Void>)

        case failTask(Error)
        case failFuture(Error)
    }

    mutating func writeNextRequestPart(_ part: IOData, taskEventLoop: EventLoop) -> WriteAction {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("Invalid state: \(self.state)")
        case .executing(let executor, let requestState, let responseState):
            switch requestState {
            case .initialized:
                preconditionFailure("Request stream must be started before it can be paused")
            case .producing:
                return .write(part, executor, taskEventLoop.makeSucceededFuture(()))

            case .paused(.none):
                // backpressure is signaled to the writer using unfulfilled futures. if there
                // is no existing, unfulfilled promise, let's create a new one
                let promise = taskEventLoop.makePromise(of: Void.self)
                self.state = .executing(executor, .paused(promise), responseState)
                return .write(part, executor, promise.futureResult)

            case .paused(.some(let promise)):
                // backpressure is signaled to the writer using unfulfilled futures. if an
                // unfulfilled promise already exist, let's reuse the promise
                return .write(part, executor, promise.futureResult)

            case .finished:
                let error = HTTPClientError.writeAfterRequestSent
                self.state = .finished(error: error)
                return .failTask(error)
            }
        case .redirected:
            // if we are redirected we can cancel the upload stream
            return .failFuture(HTTPClientError.cancelled)
        case .finished(error: .some(let error)):
            return .failFuture(error)
        case .finished(error: .none):
            return .failFuture(HTTPClientError.requestStreamCancelled)
        case .modifying:
            preconditionFailure("Invalid state")
        }
    }

    enum FinishAction {
        case forwardStreamFinished(HTTPRequestExecutor, EventLoopPromise<Void>?)
        case forwardStreamFailureAndFailTask(HTTPRequestExecutor, Error, EventLoopPromise<Void>?)
        case none
    }

    mutating func finishRequestBodyStream(_ result: Result<Void, Error>) -> FinishAction {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("Invalid state: \(self.state)")
        case .executing(let executor, let requestState, let responseState):
            switch requestState {
            case .initialized:
                preconditionFailure("Request stream must be started before it can be finished")
            case .producing:
                switch result {
                case .success:
                    self.state = .executing(executor, .finished, responseState)
                    return .forwardStreamFinished(executor, nil)
                case .failure(let error):
                    self.state = .finished(error: error)
                    return .forwardStreamFailureAndFailTask(executor, error, nil)
                }

            case .paused(let promise):
                switch result {
                case .success:
                    self.state = .executing(executor, .finished, responseState)
                    return .forwardStreamFinished(executor, promise)
                case .failure(let error):
                    self.state = .finished(error: error)
                    return .forwardStreamFailureAndFailTask(executor, error, promise)
                }

            case .finished:
                preconditionFailure("How can a finished request stream, be finished again?")
            }
        case .redirected:
            return .none
        case .finished(error: _):
            return .none
        case .modifying:
            preconditionFailure("Invalid state")
        }
    }

    /// The response head has been received.
    ///
    /// - Parameter head: The response' head
    /// - Returns: Whether the response should be forwarded to the delegate. Will be `false` if the request follows a redirect.
    mutating func receiveResponseHead(_ head: HTTPResponseHead) -> Bool {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("How can we receive a response, if the request hasn't started yet.")
        case .executing(let executor, let requestState, let responseState):
            guard case .initialized = responseState else {
                preconditionFailure("If we receive a response, we must not have received something else before")
            }

            if let redirectURL = self.redirectHandler?.redirectTarget(status: head.status, headers: head.headers) {
                self.state = .redirected(head, redirectURL)
                return false
            } else {
                self.state = .executing(executor, requestState, .buffering(.init(), next: .askExecutorForMore))
                return true
            }
        case .redirected:
            preconditionFailure("This state can only be reached after we have received a HTTP head")
        case .finished(error: .some):
            return false
        case .finished(error: .none):
            preconditionFailure("How can the request be finished without error, before receiving response head?")
        case .modifying:
            preconditionFailure("Invalid state")
        }
    }

    mutating func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) -> ByteBuffer? {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("How can we receive a response body part, if the request hasn't started yet.")
        case .executing(_, _, .initialized):
            preconditionFailure("If we receive a response body, we must have received a head before")

        case .executing(let executor, let requestState, .buffering(var currentBuffer, next: let next)):
            guard case .askExecutorForMore = next else {
                preconditionFailure("If we have received an error or eof before, why did we get another body part? Next: \(next)")
            }

            self.state = .modifying
            if currentBuffer.isEmpty {
                currentBuffer = buffer
            } else {
                currentBuffer.append(contentsOf: buffer)
            }
            self.state = .executing(executor, requestState, .buffering(currentBuffer, next: next))
            return nil
        case .executing(let executor, let requestState, .waitingForRemote):
            var buffer = buffer
            let first = buffer.removeFirst()
            self.state = .executing(executor, requestState, .buffering(buffer, next: .askExecutorForMore))
            return first
        case .redirected:
            // ignore body
            return nil
        case .finished(error: .some):
            return nil
        case .finished(error: .none):
            preconditionFailure("How can the request be finished without error, before receiving response head?")
        case .modifying:
            preconditionFailure("Invalid state")
        }
    }

    enum ReceiveResponseEndAction {
        case consume(ByteBuffer)
        case redirect(RedirectHandler<Delegate.Response>, HTTPResponseHead, URL)
        case succeedRequest
        case none
    }

    mutating func succeedRequest(_ newChunks: CircularBuffer<ByteBuffer>?) -> ReceiveResponseEndAction {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("How can we receive a response body part, if the request hasn't started yet.")
        case .executing(_, _, .initialized):
            preconditionFailure("If we receive a response body, we must have received a head before")

        case .executing(let executor, let requestState, .buffering(var buffer, next: let next)):
            guard case .askExecutorForMore = next else {
                preconditionFailure("If we have received an error or eof before, why did we get another body part? Next: \(next)")
            }

            if buffer.isEmpty, newChunks == nil || newChunks!.isEmpty {
                self.state = .finished(error: nil)
                return .succeedRequest
            } else if buffer.isEmpty, let newChunks = newChunks {
                buffer = newChunks
            } else if let newChunks = newChunks {
                buffer.append(contentsOf: newChunks)
            }

            self.state = .executing(executor, requestState, .buffering(buffer, next: .eof))
            return .none

        case .executing(let executor, let requestState, .waitingForRemote):
            guard var newChunks = newChunks, !newChunks.isEmpty else {
                self.state = .finished(error: nil)
                return .succeedRequest
            }

            let first = newChunks.removeFirst()
            self.state = .executing(executor, requestState, .buffering(newChunks, next: .eof))
            return .consume(first)

        case .redirected(let head, let redirectURL):
            self.state = .finished(error: nil)
            return .redirect(self.redirectHandler!, head, redirectURL)

        case .finished(error: .some):
            return .none

        case .finished(error: .none):
            preconditionFailure("How can the request be finished without error, before receiving response head?")
        case .modifying:
            preconditionFailure("Invalid state")
        }
    }

    enum ConsumeAction {
        case requestMoreFromExecutor(HTTPRequestExecutor)
        case consume(ByteBuffer)
        case finishStream
        case failTask(Error, executorToCancel: HTTPRequestExecutor?)
        case doNothing
    }

    mutating func consumeMoreBodyData(resultOfPreviousConsume result: Result<Void, Error>) -> ConsumeAction {
        switch result {
        case .success:
            return self.consumeMoreBodyData()
        case .failure(let error):
            return self.failWithConsumptionError(error)
        }
    }

    private mutating func failWithConsumptionError(_ error: Error) -> ConsumeAction {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("Invalid state")
        case .executing(_, _, .initialized):
            preconditionFailure("Invalid state: Must have received response head, before this method is called for the first time")

        case .executing(_, _, .buffering(_, next: .error(let connectionError))):
            // if an error was received from the connection, we fail the task with the one
            // from the connection, since it happened first.
            self.state = .finished(error: connectionError)
            return .failTask(connectionError, executorToCancel: nil)

        case .executing(let executor, _, .buffering(_, _)):
            self.state = .finished(error: error)
            return .failTask(error, executorToCancel: executor)

        case .executing(_, _, .waitingForRemote):
            preconditionFailure("Invalid state... We just returned from a consumption function. We can't already be waiting")

        case .redirected:
            preconditionFailure("Invalid state... Redirect don't call out to delegate functions. Thus we should never land here.")

        case .finished(error: .some):
            // don't overwrite existing errors
            return .doNothing

        case .finished(error: .none):
            preconditionFailure("Invalid state... If no error occured, this must not be called, after the request was finished")

        case .modifying:
            preconditionFailure()
        }
    }

    private mutating func consumeMoreBodyData() -> ConsumeAction {
        switch self.state {
        case .initialized, .queued:
            preconditionFailure("Invalid state")
        case .executing(_, _, .initialized):
            preconditionFailure("Invalid state: Must have received response head, before this method is called for the first time")
        case .executing(let executor, let requestState, .buffering(var buffer, next: .askExecutorForMore)):
            self.state = .modifying

            if let byteBuffer = buffer.popFirst() {
                self.state = .executing(executor, requestState, .buffering(buffer, next: .askExecutorForMore))
                return .consume(byteBuffer)
            }

            // buffer is empty, wait for more
            self.state = .executing(executor, requestState, .waitingForRemote)
            return .requestMoreFromExecutor(executor)

        case .executing(let executor, let requestState, .buffering(var buffer, next: .eof)):
            self.state = .modifying

            if let byteBuffer = buffer.popFirst() {
                self.state = .executing(executor, requestState, .buffering(buffer, next: .eof))
                return .consume(byteBuffer)
            }

            self.state = .finished(error: nil)
            return .finishStream

        case .executing(_, _, .buffering(_, next: .error(let error))):
            self.state = .finished(error: error)
            return .failTask(error, executorToCancel: nil)

        case .executing(_, _, .waitingForRemote):
            preconditionFailure("Invalid state... We just returned from a consumption function. We can't already be waiting")

        case .redirected:
            return .doNothing

        case .finished(error: .some):
            return .doNothing

        case .finished(error: .none):
            preconditionFailure("Invalid state... If no error occured, this must not be called, after the request was finished")

        case .modifying:
            preconditionFailure()
        }
    }

    enum FailAction {
        case failTask(HTTPRequestScheduler?, HTTPRequestExecutor?)
        case cancelExecutor(HTTPRequestExecutor)
        case none
    }

    mutating func fail(_ error: Error) -> FailAction {
        switch self.state {
        case .initialized:
            self.state = .finished(error: error)
            return .failTask(nil, nil)
        case .queued(let queuer):
            self.state = .finished(error: error)
            return .failTask(queuer, nil)
        case .executing(let executor, let requestState, .buffering(_, next: .eof)):
            self.state = .executing(executor, requestState, .buffering(.init(), next: .error(error)))
            return .cancelExecutor(executor)
        case .executing(let executor, _, .buffering(_, next: .askExecutorForMore)):
            self.state = .finished(error: error)
            return .failTask(nil, executor)
        case .executing(let executor, _, .buffering(_, next: .error(_))):
            // this would override another error, let's keep the first one
            return .cancelExecutor(executor)
        case .executing(let executor, _, .initialized):
            self.state = .finished(error: error)
            return .failTask(nil, executor)
        case .executing(let executor, _, .waitingForRemote):
            self.state = .finished(error: error)
            return .failTask(nil, executor)
        case .redirected:
            self.state = .finished(error: error)
            return .failTask(nil, nil)
        case .finished(.none):
            // An error occurred after the request has finished. Ignore...
            return .none
        case .finished(.some(_)):
            // this might happen, if the stream consumer has failed... let's just drop the data
            return .none
        case .modifying:
            preconditionFailure("Invalid state")
        }
    }
}
