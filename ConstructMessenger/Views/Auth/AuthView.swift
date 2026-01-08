//
//  AuthView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

struct AuthView: View {
    @EnvironmentObject var viewModel: AuthViewModel
    @State private var showingRegister = false

    var body: some View {
        NavigationStack {
       
                VStack(spacing: 20) {
                    
                    Text("construct_messenger")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding(.top, 30)
                    
                    
                    #if DEBUG
                    ServerInfoBanner()
                    #endif
                    
                    if viewModel.isLoading {
                        ProgressView()
                            .padding()
                    }
                    
                    Spacer()

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                    
                    Button {
                        withAnimation {
                            showingRegister.toggle()
                        }
                    } label: {
                        Text(showingRegister ? "back_to_login" : "register")
                            .foregroundColor(.blue)
                    }

                    if showingRegister {
                        RegisterView(viewModel: viewModel)
                    } else {
                        LoginView(viewModel: viewModel)
                    }
                    
                    Spacer()
                    
                }
                .padding()
            
        }
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    return AuthView()
        .environmentObject(AuthViewModel(context: container.viewContext))
}

