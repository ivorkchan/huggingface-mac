//
//  ConversationModel.swift
//  HuggingChat-Mac
//
//  Created by Cyril Zakka on 8/29/24.
//

import SwiftUI
import Combine

enum ConversationState: Equatable {
    case none, empty, loaded, loading, generating, error
}

@Observable final class ConversationViewModel {
    
    var isInteracting = false
    var model: AnyObject?
    var message: MessageRow? = nil
    var error: HFError?
    
    // Currently the best way to get @AppStorage value while returning observability
    var useWebService: Bool {
        get {
            access(keyPath: \.useWebService)
            return UserDefaults.standard.bool(forKey: "useWebSearch")
        }
        set {
            withMutation(keyPath: \.useWebService) {
                UserDefaults.standard.setValue(newValue, forKey: "useWebSearch")
            }
        }
    }
    
    private var cancellables = [AnyCancellable]()
    private var sendPromptHandler: SendPromptHandler?
    
    private(set) var conversation: Conversation? {
        didSet {
            guard let conversation = conversation else { return }
            HuggingChatSession.shared.currentConversation = conversation.id
        }
    }
    
    var state: ConversationState = .none
    
    private func createConversationAndSendPrompt(_ prompt: String) {
        if let model = model as? LLMModel {
            createConversation(with: model, prompt: prompt)
        }
    }
    
    private func createConversation(with model: LLMModel, prompt: String) {
        state = .loaded
        NetworkService.createConversation(base: model)
            .receive(on: DispatchQueue.main).sink { completion in
                switch completion {
                case .finished:
                    print("ConversationViewModel.createConversation finished")
                case .failure(let error):
                    print("ConversationViewModel.createConversation failed:\n\(error)")
                    self.state = .error
                    self.error = .verbose("Something's wrong. Check your internet connection and try again.")
                }
            } receiveValue: { [weak self] conversation in
                self?.conversation = conversation
                self?.sendAttributed(text: prompt)
            }.store(in: &cancellables)
    }
    
    func sendAttributed(text: String) {
        guard let conversation = conversation, let previousId = conversation.messages.last?.id else {
            createConversationAndSendPrompt(text)
            return
        }
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        let req = PromptRequestBody(id: previousId, inputs: trimmedText, webSearch: useWebService)
        sendPromptRequest(req: req, conversationID: conversation.id)
    }
    
    private func sendPromptRequest(req: PromptRequestBody, conversationID: String) {
        state = .generating
        isInteracting = true
        let sendPromptHandler = SendPromptHandler(conversationId: conversationID)
        self.sendPromptHandler = sendPromptHandler
//        let messageRow = sendPromptHandler.messageRow
        
        let pub = sendPromptHandler.update
            .receive(on: RunLoop.main).eraseToAnyPublisher()

        pub.scan((0, nil), { (tuple, prod) in
            (tuple.0 + 1, prod)
        }).eraseToAnyPublisher()
            .sink { [weak self] completion in
                guard let self else { return }
                switch completion {
                case .finished:
                    print("ConversationViewModel.Message Reception Completed")
                    self.sendPromptHandler = nil
                    isInteracting = false
                    self.sendPromptHandler = nil
                    state = .loaded
                case .failure(let error):
                    switch error {
                    case .httpTooManyRequest:
                        self.state = .error
                        self.error = .verbose("You've sent too many requests. Please try logging in before sending a message.")
                        print("Too Many Requests")
                    default:
                        self.state = .error
                        self.error = error
                        print(error.localizedDescription)
                    }
                }
            } receiveValue: { [weak self] obj in
                let (count, messageRow) = obj
                if count == 1 {
                    self?.updateConversation(conversationID: conversationID)
                }
                self?.message = messageRow
                
            }.store(in: &cancellables)

        sendPromptHandler.sendPromptReq(reqBody: req)
    }
    
    private func updateConversation(conversationID: String) {
        NetworkService.getConversation(id: conversationID).sink { completion in
            switch completion {
            case .finished:
                print("ConversationViewModel.updateConversation finished")
            case .failure(let error):
                self.state = .error
                self.error = .verbose("Uh oh, something's not right! Please check your connection and try again later.")
                print(error.localizedDescription)
            }
        } receiveValue: { [weak self] conversation in
            self?.conversation = conversation
//            self?.updateIDs(conversation: conversation)
        }.store(in: &cancellables)
    }
    
    func getActiveModel() {
        DataService.shared.getActiveModel().receive(on: DispatchQueue.main).sink { completion in
            switch completion {
            case .finished:
                print("ConversationViewModel.getActiveModel finished")
            case .failure(let error):
                self.state = .error
                self.error = .verbose("Hmm, that didn't go as planned. Please check your connection and try again.")
                print("ConversationViewModel.getActiveModel failed:\n \(error)")
            }
        } receiveValue: { [weak self] model in
            self?.model = model
        }.store(in: &cancellables)
    }
    
    func reset() {
        state = .empty
        getActiveModel()
        cancellables = []
        conversation = nil
        error = nil
        isInteracting = false
        HuggingChatSession.shared.currentConversation = ""
    }
    
    func stopGenerating() {
        cancellables = []
        sendPromptHandler?.cancel()
        completeInteration()
    }
    
    private func completeInteration() {
        isInteracting = false
        sendPromptHandler = nil
        state = .loaded
        error = nil
    }
    
}
