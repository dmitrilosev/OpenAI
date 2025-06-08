//
//  StreamingSession.swift
//
//
//  Created by Sergii Kryvoblotskyi on 18/04/2023.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StreamingSession<Interpreter: StreamInterpreter>: NSObject, Identifiable, URLSessionDataDelegateProtocol, @unchecked Sendable {
    typealias ResultType = Interpreter.ResultType
    
    private let urlSessionFactory: URLSessionFactory
    private let urlRequest: URLRequest
    private let interpreter: Interpreter
    private let sslDelegate: SSLDelegateProtocol?
    private let middlewares: [OpenAIMiddleware]
    private let executionSerializer: ExecutionSerializer
    private let onReceiveContent: (@Sendable (StreamingSession, ResultType) -> Void)?
    private let onProcessingError: (@Sendable (StreamingSession, Error) -> Void)?
    private let onComplete: (@Sendable (StreamingSession, Error?) -> Void)?
    private var receivedHTTPResponse: HTTPURLResponse?
    private var errorData = Data()
    private var didReceiveErrorResponse = false
    
    init(
        urlSessionFactory: URLSessionFactory = FoundationURLSessionFactory(),
        urlRequest: URLRequest,
        interpreter: Interpreter,
        sslDelegate: SSLDelegateProtocol?,
        middlewares: [OpenAIMiddleware],
        executionSerializer: ExecutionSerializer = GCDQueueAsyncExecutionSerializer(queue: .userInitiated),
        onReceiveContent: @escaping @Sendable (StreamingSession, ResultType) -> Void,
        onProcessingError: @escaping @Sendable (StreamingSession, Error) -> Void,
        onComplete: @escaping @Sendable (StreamingSession, Error?) -> Void
    ) {
        self.urlSessionFactory = urlSessionFactory
        self.urlRequest = urlRequest
        self.interpreter = interpreter
        self.sslDelegate = sslDelegate
        self.middlewares = middlewares
        self.executionSerializer = executionSerializer
        self.onReceiveContent = onReceiveContent
        self.onProcessingError = onProcessingError
        self.onComplete = onComplete
        super.init()
        subscribeToParser()
    }
    
    func makeSession() -> PerformableSession & InvalidatableSession {
        let urlSession = urlSessionFactory.makeUrlSession(delegate: self)
        return DataTaskPerformingURLSession(urlRequest: urlRequest, urlSession: urlSession)
    }
    
    func urlSession(_ session: any URLSessionProtocol, task: any URLSessionTaskProtocol, didCompleteWithError error: (any Error)?) {
        executionSerializer.dispatch {
            if self.didReceiveErrorResponse {
                if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: self.errorData) {
                    self.onProcessingError?(self, apiError)
                    self.onComplete?(self, apiError)
                } else if let httpResponse = self.receivedHTTPResponse {
                    let err = OpenAIError.statusError(response: httpResponse, statusCode: httpResponse.statusCode)
                    self.onProcessingError?(self, err)
                    self.onComplete?(self, err)
                } else {
                    self.onProcessingError?(self, error ?? OpenAIError.emptyData)
                    self.onComplete?(self, error)
                }
            } else {
                self.onComplete?(self, error)
            }
        }
    }
    
    func urlSession(_ session: any URLSessionProtocol, dataTask: any URLSessionDataTaskProtocol, didReceive data: Data) {
        executionSerializer.dispatch {
            if self.didReceiveErrorResponse {
                self.errorData.append(data)
                return
            }
            let data = self.middlewares.reduce(data) { current, middleware in
                middleware.interceptStreamingData(request: dataTask.originalRequest, current)
            }
            self.interpreter.processData(data)
        }
    }

    func urlSession(
        _ session: URLSessionProtocol,
        dataTask: URLSessionDataTaskProtocol,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        executionSerializer.dispatch {
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                self.receivedHTTPResponse = httpResponse
                self.didReceiveErrorResponse = true
                completionHandler(.allow)
                return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let sslDelegate else { return completionHandler(.performDefaultHandling, nil) }
        sslDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    private func subscribeToParser() {
        interpreter.setCallbackClosures { [weak self] content in
            guard let self else { return }
            self.onReceiveContent?(self, content)
        } onError: { [weak self] error in
            guard let self else { return }
            self.onProcessingError?(self, error)
        }
    }
}
