import SwiftUI

// MARK: - App State

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var showSettings = false
    /// 0 = system, 1 = light, 2 = dark
    @Published var appearanceMode: Int = UserDefaults.standard.integer(forKey: "talkie_appearance_mode") {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "talkie_appearance_mode") }
    }
    @Published var textSizePercent: Double = {
        let saved = UserDefaults.standard.double(forKey: "talkie_text_size_pct")
        return saved > 0 ? saved : 100
    }() {
        didSet { UserDefaults.standard.set(textSizePercent, forKey: "talkie_text_size_pct") }
    }

    var colorScheme: ColorScheme? {
        switch appearanceMode {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }
}

// MARK: - Settings View Model

class SettingsViewModel: ObservableObject {
    static let shared = SettingsViewModel()

    @Published var systemPrompt = ""
    @Published var memory = ""
    @Published var useApplePersonalVoice = false
    @Published var useElevenLabs = false
    @Published var elApiKey = ""
    @Published var voiceId = ""
    @Published var devMode = false
    @Published var hasELConsent = false

    var onReplayTutorial: (() -> Void)?
    var onResetAll: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenVoiceCloning: (() -> Void)?
    var onTextSizeChanged: ((Double) -> Void)?
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm = SettingsViewModel.shared
    @ObservedObject var appState = AppState.shared
    @State private var showResetConfirm = false
    @State private var showELConsent = false
    @State private var devTapCount = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Intelligence") {
                    NavigationLink {
                        SystemPromptView(prompt: $vm.systemPrompt)
                    } label: {
                        Label("Prompt système", systemImage: "text.bubble")
                    }

                    NavigationLink {
                        MemoryView(memory: $vm.memory)
                    } label: {
                        Label("Mémoire IA", systemImage: "brain")
                    }

                    Toggle(isOn: $vm.useApplePersonalVoice) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voix personnelle")
                            Text("Configurée dans Réglages iOS \u{2192} Accessibilité")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Accessibilité") {
                    Picker("Apparence", selection: $appState.appearanceMode) {
                        Text("Système").tag(0)
                        Text("Clair").tag(1)
                        Text("Sombre").tag(2)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Taille du texte")
                            Spacer()
                            Text("\(Int(appState.textSizePercent))%")
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text("A").font(.caption)
                            Slider(value: $appState.textSizePercent, in: 80...150, step: 5)
                                .onChange(of: appState.textSizePercent) { newValue in
                                    vm.onTextSizeChanged?(newValue)
                                }
                            Text("A").font(.title3)
                        }
                    }
                }

                Section("À propos") {
                    Button {
                        vm.onReplayTutorial?()
                        dismiss()
                    } label: {
                        Label("Tutoriel", systemImage: "questionmark.circle")
                    }

                    NavigationLink {
                        PrivacyPolicyNativeView()
                    } label: {
                        Label("Politique de confidentialité", systemImage: "hand.raised")
                    }

                    NavigationLink {
                        SupportNativeView()
                    } label: {
                        Label("Support", systemImage: "lifepreserver")
                    }

                    NavigationLink {
                        ReportNativeView()
                    } label: {
                        Label("Signaler un problème", systemImage: "exclamationmark.triangle")
                    }
                }

                if vm.devMode {
                    Section("Mode développeur") {
                        Toggle(isOn: Binding(
                            get: { vm.useElevenLabs },
                            set: { newValue in
                                if newValue && !vm.hasELConsent {
                                    showELConsent = true
                                } else {
                                    vm.useElevenLabs = newValue
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("ElevenLabs TTS")
                                Text("Synthèse vocale via l'API ElevenLabs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if vm.useElevenLabs {
                            SecureField("Clé API ElevenLabs", text: $vm.elApiKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            TextField("Voice ID", text: $vm.voiceId)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    vm.onOpenVoiceCloning?()
                                }
                            } label: {
                                Label("Clonage vocal (avancé)", systemImage: "waveform.badge.plus")
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Réinitialiser l'application")
                            Spacer()
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text("Talkie v2.2.0")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .onTapGesture {
                                devTapCount += 1
                                if devTapCount >= 5 {
                                    devTapCount = 0
                                    withAnimation { vm.devMode.toggle() }
                                }
                                let captured = devTapCount
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    if self.devTapCount == captured {
                                        self.devTapCount = 0
                                    }
                                }
                            }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
            }
            .alert("Réinitialiser ?", isPresented: $showResetConfirm) {
                Button("Annuler", role: .cancel) {}
                Button("Réinitialiser", role: .destructive) {
                    vm.onResetAll?()
                    dismiss()
                }
            } message: {
                Text("Toutes vos données seront supprimées. Cette action est irréversible.")
            }
            .alert("ElevenLabs", isPresented: $showELConsent) {
                Button("Annuler", role: .cancel) {}
                Button("Accepter") {
                    vm.hasELConsent = true
                    vm.useElevenLabs = true
                }
            } message: {
                Text("En activant ElevenLabs, vos textes seront envoyés aux serveurs d'ElevenLabs pour la synthèse vocale. Aucune donnée n'est conservée par Talkie.")
            }
        }
    }
}

// MARK: - System Prompt View

struct SystemPromptView: View {
    @Binding var prompt: String

    private let defaultPrompt = """
Tu es un assistant qui aide une personne ayant des difficultés à parler (SLA, mutisme ou autre) à communiquer.
Tu proposes des réponses naturelles et chaleureuses en français.
Sois concis et naturel. La personne peut avoir du mal à taper, propose des réponses courtes et utiles.
Tu ne dois JAMAIS générer de contenu violent, haineux, sexuel, discriminatoire ou illégal. Si on te le demande, refuse poliment.
"""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 200)
            } header: {
                Text("Ce prompt modifie le comportement global de l'assistant.")
            }

            Section {
                Button("Réinitialiser aux valeurs par défaut") {
                    prompt = defaultPrompt
                }
            }
        }
        .navigationTitle("Prompt système")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Memory View

struct MemoryView: View {
    @Binding var memory: String

    var body: some View {
        Form {
            Section {
                TextEditor(text: $memory)
                    .frame(minHeight: 200)
            } header: {
                Text("Talkie retient des informations pour personnaliser les réponses.")
            } footer: {
                Text("Ex: J'aime le football, j'ai 2 enfants, je suis ingénieur...")
            }
        }
        .navigationTitle("Mémoire IA")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy Policy View

struct PrivacyPolicyNativeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Dernière mise à jour : Mars 2026")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    Text("Résumé").font(.headline)
                    Text("Talkie respecte votre vie privée. Toutes vos données restent sur votre appareil. Aucune donnée personnelle n'est collectée ni transmise à nos serveurs.")
                }

                Group {
                    Text("Données stockées localement").font(.headline)
                    Text("Les informations suivantes sont stockées uniquement sur votre iPhone :")
                    VStack(alignment: .leading, spacing: 4) {
                        BulletText("Votre nom (si renseigné)")
                        BulletText("L'historique des conversations (les 20 derniers échanges)")
                        BulletText("Les informations retenues par la mémoire IA")
                        BulletText("Le prompt système personnalisé")
                        BulletText("Les échantillons vocaux (si fournis)")
                    }
                }

                Group {
                    Text("ElevenLabs (optionnel)").font(.headline)
                    Text("Si vous activez la voix ElevenLabs, votre clé API est stockée de manière sécurisée dans le Keychain iOS. Lorsque vous utilisez cette fonctionnalité, le texte de vos réponses est envoyé aux serveurs d'ElevenLabs pour la synthèse vocale. Aucune donnée audio ou textuelle n'est conservée par Talkie. Votre consentement est demandé avant la première activation.")
                }

                Group {
                    Text("Apple Intelligence").font(.headline)
                    Text("Les suggestions IA sont générées localement via Apple Intelligence sur votre appareil. Aucune donnée de conversation n'est envoyée à des serveurs tiers pour cette fonctionnalité.")
                }

                Group {
                    Text("Reconnaissance vocale").font(.headline)
                    Text("La reconnaissance vocale utilise l'API Web Speech de votre navigateur intégré. Le traitement peut impliquer les serveurs d'Apple conformément à leur politique de confidentialité.")
                }

                Group {
                    Text("Suppression des données").font(.headline)
                    Text("Vous pouvez supprimer toutes vos données à tout moment dans Réglages \u{2192} Réinitialiser l'application.")
                }

                Group {
                    Text("Contact").font(.headline)
                    Text("talkie-app@proton.me")
                        .foregroundStyle(.accent)
                }
            }
            .padding()
        }
        .navigationTitle("Confidentialité")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Support View

struct SupportNativeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Comment utiliser Talkie").font(.headline)
                    Text("Talkie est une application de communication assistée conçue pour les personnes vivant avec la SLA (maladie de Charcot), les personnes muettes ou ayant des difficultés à parler.")
                }

                Group {
                    Text("Fonctionnement").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        SupportItemView(title: "Écoute", desc: "Appuyez sur la barre d'écoute pour activer le micro. Talkie transcrit ce que dit votre interlocuteur.")
                        SupportItemView(title: "Suggestions", desc: "Apple Intelligence propose 3 réponses automatiquement.")
                        SupportItemView(title: "Parler", desc: "Appuyez sur une suggestion pour la prononcer à voix haute.")
                        SupportItemView(title: "Saisie libre", desc: "Utilisez le bouton « Écrire » pour taper manuellement votre message.")
                    }
                }

                Group {
                    Text("Questions fréquentes").font(.headline)

                    FAQItemView(q: "Le micro ne fonctionne pas ?", a: "Vérifiez que Talkie a l'autorisation d'accéder au microphone dans Réglages iOS \u{2192} Talkie.")
                    FAQItemView(q: "Les suggestions n'apparaissent pas ?", a: "Assurez-vous qu'Apple Intelligence est activé dans Réglages iOS \u{2192} Apple Intelligence et Siri.")
                    FAQItemView(q: "Comment supprimer mes données ?", a: "Allez dans Réglages Talkie \u{2192} Réinitialiser l'application.")
                }

                Group {
                    Text("Contact").font(.headline)
                    Text("talkie-app@proton.me")
                        .foregroundStyle(.accent)
                }
            }
            .padding()
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Report View

struct ReportNativeView: View {
    @State private var reportText = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $reportText)
                    .frame(minHeight: 150)
            } header: {
                Text("Bug, contenu inapproprié, ou suggestion d'amélioration")
            }

            Section {
                Button("Envoyer par e-mail") {
                    sendReport()
                }
                .disabled(reportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("Un e-mail sera préparé avec votre description. Vous pourrez le vérifier avant envoi.")
            }
        }
        .navigationTitle("Signaler")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendReport() {
        let subject = "Talkie - Signalement".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = (reportText + "\n\n---\nVersion: v2.2.0").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:talkie-app@proton.me?subject=\(subject)&body=\(body)") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Helper Views

struct BulletText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .foregroundStyle(.secondary)
            Text(text)
        }
    }
}

struct SupportItemView: View {
    let title: String
    let desc: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).bold()
            Text(desc).foregroundStyle(.secondary)
        }
    }
}

struct FAQItemView: View {
    let q: String
    let a: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q).bold()
            Text(a).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}
