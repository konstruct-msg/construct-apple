//
//  DevicesView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 09.02.2026.
//

import SwiftUI


struct DevicesView: View {
    
    var body: some View {
        
        List {
            Section {
                Text("Link new device to your account")
                
                Button {
                   
                } label: {
                    Text("Link device")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
            }
        }
    }
}
