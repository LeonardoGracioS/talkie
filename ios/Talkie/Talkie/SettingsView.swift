import SwiftUI

// MARK: - Quick Phrase Model

struct QuickPhrase: Identifiable, Codable, Equatable {
    var id = UUID()
    var emoji: String
    var text: String
}

// MARK: - App State

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var showSettings = false
    /// 0 = system, 1 = light, 2 = dark
    @Published var appearanceMode: Int = UserDefaults.standard.integer(forKey: "talkie_appearance_mode") {
        didSet {
            UserDefaults.standard.set(appearanceMode, forKey: "talkie_appearance_mode")
            Self.applyAppearance(appearanceMode)
        }
    }

    static func applyAppearance(_ mode: Int) {
        let apply = {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first else { return }
            switch mode {
            case 1: window.overrideUserInterfaceStyle = .light
            case 2: window.overrideUserInterfaceStyle = .dark
            default: window.overrideUserInterfaceStyle = .unspecified
            }
        }
        // Synchrone sur le main : sinon `WebAppView.updateUIView` peut lire le trait fenêtre
        // encore en « clair » juste après passage Apparence → Système.
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
    @Published var textSizePercent: Double = {
        let saved = UserDefaults.standard.double(forKey: "talkie_text_size_pct")
        return saved > 0 ? saved : 100
    }() {
        didSet { UserDefaults.standard.set(textSizePercent, forKey: "talkie_text_size_pct") }
    }
    @Published var oledMode: Bool = UserDefaults.standard.bool(forKey: "talkie_oled_mode") {
        didSet { UserDefaults.standard.set(oledMode, forKey: "talkie_oled_mode") }
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

    @Published var memory = ""
    @Published var learnedMemory = ""
    @Published var lang = "fr"
    @Published var useApplePersonalVoice = false
    @Published var useElevenLabs = false
    @Published var elApiKey = ""
    @Published var voiceId = ""
    @Published var devMode = false
    @Published var hasELConsent = false
    @Published var quickPhrases: [QuickPhrase] = []

    var onReplayTutorial: (() -> Void)?
    var onResetAll: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenVoiceCloning: (() -> Void)?
    var onTextSizeChanged: ((Double) -> Void)?
    var onClearLearnedMemory: (() -> Void)?
    var onLanguageChanged: ((String) -> Void)?
    var onQuickPhrasesChanged: (([QuickPhrase]) -> Void)?
    var onOledModeChanged: ((Bool) -> Void)?
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
                Section(vm.lang == "fr" ? "Langue" : "Language") {
                    Picker(vm.lang == "fr" ? "Langue" : "Language", selection: $vm.lang) {
                        Text("Français").tag("fr")
                        Text("English").tag("en")
                    }
                    .onChange(of: vm.lang) { _, newValue in
                        vm.onLanguageChanged?(newValue)
                    }
                }

                Section(vm.lang == "fr" ? "Phrases rapides" : "Quick Phrases") {
                    NavigationLink {
                        QuickPhrasesView(phrases: $vm.quickPhrases, lang: vm.lang, onChanged: vm.onQuickPhrasesChanged)
                    } label: {
                        Label(vm.lang == "fr" ? "Phrases rapides" : "Quick Phrases", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }

                Section("Apple Intelligence") {
                    NavigationLink {
                        MemoryView(memory: $vm.memory, learnedMemory: $vm.learnedMemory, lang: vm.lang, onClearLearnedMemory: vm.onClearLearnedMemory)
                    } label: {
                        Label(vm.lang == "fr" ? "Mémoire IA" : "AI Memory", systemImage: "brain")
                    }

                    Toggle(isOn: $vm.useApplePersonalVoice) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.lang == "fr" ? "Voix personnelle" : "Personal Voice")
                            Text(vm.lang == "fr" ? "Configurée dans Réglages iOS \u{2192} Accessibilité" : "Configured in iOS Settings \u{2192} Accessibility")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(vm.lang == "fr" ? "Accessibilité" : "Accessibility") {
                    Picker(vm.lang == "fr" ? "Apparence" : "Appearance", selection: $appState.appearanceMode) {
                        Text(vm.lang == "fr" ? "Système" : "System").tag(0)
                        Text(vm.lang == "fr" ? "Clair" : "Light").tag(1)
                        Text(vm.lang == "fr" ? "Sombre" : "Dark").tag(2)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(vm.lang == "fr" ? "Taille du texte" : "Text size")
                            Spacer()
                            Text("\(Int(appState.textSizePercent))%")
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text("A").font(.caption)
                            Slider(value: $appState.textSizePercent, in: 80...150, step: 5)
                                .onChange(of: appState.textSizePercent) { _, newValue in
                                    vm.onTextSizeChanged?(newValue)
                                }
                            Text("A").font(.title3)
                        }
                    }

                    Toggle(isOn: $appState.oledMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.lang == "fr" ? "Mode OLED" : "OLED Mode")
                            Text(vm.lang == "fr" ? "Noir profond pour écrans OLED, contraste maximal" : "Deep black for OLED screens, maximum contrast")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: appState.oledMode) { _, newValue in
                        vm.onOledModeChanged?(newValue)
                    }
                }

                Section(vm.lang == "fr" ? "À propos" : "About") {
                    Button {
                        vm.onReplayTutorial?()
                        dismiss()
                    } label: {
                        Label(vm.lang == "fr" ? "Tutoriel" : "Tutorial", systemImage: "questionmark.circle")
                    }

                    NavigationLink {
                        PrivacyPolicyNativeView()
                    } label: {
                        Label(vm.lang == "fr" ? "Politique de confidentialité" : "Privacy Policy", systemImage: "hand.raised")
                    }

                    NavigationLink {
                        SupportNativeView()
                    } label: {
                        Label("Support", systemImage: "lifepreserver")
                    }

                    NavigationLink {
                        ReportNativeView()
                    } label: {
                        Label(vm.lang == "fr" ? "Signaler un problème" : "Report an issue", systemImage: "exclamationmark.triangle")
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
                            Text(vm.lang == "fr" ? "Réinitialiser l'application" : "Reset application")
                            Spacer()
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text("Talkie v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.0")")
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
            .navigationTitle(vm.lang == "fr" ? "Réglages" : "Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(vm.lang == "fr" ? "Fermer" : "Close") { dismiss() }
                }
            }
            .alert(vm.lang == "fr" ? "Réinitialiser ?" : "Reset?", isPresented: $showResetConfirm) {
                Button(vm.lang == "fr" ? "Annuler" : "Cancel", role: .cancel) {}
                Button(vm.lang == "fr" ? "Réinitialiser" : "Reset", role: .destructive) {
                    vm.onResetAll?()
                    dismiss()
                }
            } message: {
                Text(vm.lang == "fr" ? "Toutes vos données seront supprimées. Cette action est irréversible." : "All your data will be deleted. This action is irreversible.")
            }
            .alert("ElevenLabs", isPresented: $showELConsent) {
                Button(vm.lang == "fr" ? "Annuler" : "Cancel", role: .cancel) {}
                Button(vm.lang == "fr" ? "Accepter" : "Accept") {
                    vm.hasELConsent = true
                    vm.useElevenLabs = true
                }
            } message: {
                Text(vm.lang == "fr" ? "En activant ElevenLabs, vos textes seront envoyés aux serveurs d'ElevenLabs pour la synthèse vocale. Aucune donnée n'est conservée par Talkie." : "By enabling ElevenLabs, your text will be sent to ElevenLabs servers for speech synthesis. No data is stored by Talkie.")
            }
        }
    }
}

// MARK: - Memory View

struct MemoryView: View {
    @Binding var memory: String
    @Binding var learnedMemory: String
    var lang: String
    var onClearLearnedMemory: (() -> Void)?
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $memory)
                    .frame(minHeight: 200)
            } header: {
                Text(lang == "fr" ? "Talkie retient des informations pour personnaliser les réponses." : "Talkie remembers information to personalize responses.")
            } footer: {
                Text(lang == "fr" ? "Ex: J'aime le football, j'ai 2 enfants, je suis ingénieur..." : "E.g.: I like football, I have 2 kids, I'm an engineer...")
            }

            Section {
                TextEditor(text: $learnedMemory)
                    .frame(minHeight: 120)
            } header: {
                Text(lang == "fr" ? "Appris des conversations" : "Learned from conversations")
            } footer: {
                Text(lang == "fr" ? "Talkie apprend automatiquement des détails à partir de vos échanges. Vous pouvez modifier ou effacer ces informations." : "Talkie automatically learns details from your conversations. You can edit or clear this information.")
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text(lang == "fr" ? "Effacer la mémoire apprise" : "Clear learned memory")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(lang == "fr" ? "Mémoire IA" : "AI Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(lang == "fr" ? "OK" : "Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .alert(lang == "fr" ? "Effacer ?" : "Clear?", isPresented: $showClearConfirm) {
            Button(lang == "fr" ? "Annuler" : "Cancel", role: .cancel) {}
            Button(lang == "fr" ? "Effacer" : "Clear", role: .destructive) {
                learnedMemory = ""
                onClearLearnedMemory?()
            }
        } message: {
            Text(lang == "fr" ? "La mémoire apprise sera supprimée." : "Learned memory will be deleted.")
        }
    }
}

// MARK: - Quick Phrases View

struct QuickPhrasesView: View {
    @Binding var phrases: [QuickPhrase]
    var lang: String
    var onChanged: (([QuickPhrase]) -> Void)?
    @State private var showAddSheet = false
    @State private var newEmoji = ""
    @State private var newText = ""

    private static let defaultPhrasesFR: [QuickPhrase] = [
        QuickPhrase(emoji: "✋", text: "Attends"),
        QuickPhrase(emoji: "❌", text: "Non"),
        QuickPhrase(emoji: "✅", text: "Oui"),
        QuickPhrase(emoji: "🤔", text: "Je réfléchis"),
        QuickPhrase(emoji: "✍️", text: "J\u{2019}écris ma réponse"),
        QuickPhrase(emoji: "😊", text: "Haha"),
        QuickPhrase(emoji: "👋", text: "Bonjour"),
        QuickPhrase(emoji: "🙏", text: "Merci"),
    ]

    private static let defaultPhrasesEN: [QuickPhrase] = [
        QuickPhrase(emoji: "✋", text: "Wait"),
        QuickPhrase(emoji: "❌", text: "No"),
        QuickPhrase(emoji: "✅", text: "Yes"),
        QuickPhrase(emoji: "🤔", text: "Let me think"),
        QuickPhrase(emoji: "✍️", text: "I\u{2019}m typing"),
        QuickPhrase(emoji: "😊", text: "Haha"),
        QuickPhrase(emoji: "👋", text: "Hello"),
        QuickPhrase(emoji: "🙏", text: "Thanks"),
    ]

    private var displayPhrases: [QuickPhrase] {
        phrases.isEmpty ? (lang == "fr" ? Self.defaultPhrasesFR : Self.defaultPhrasesEN) : phrases
    }

    var body: some View {
        List {
            Section {
                ForEach(displayPhrases) { phrase in
                    HStack(spacing: 12) {
                        Text(phrase.emoji)
                            .font(.title2)
                        Text(phrase.text)
                            .font(.body)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: deletePhrase)
                .onMove(perform: movePhrase)
            } header: {
                Text(lang == "fr" ? "Appuyez sur une phrase pour la prononcer instantanément" : "Tap a phrase to speak it instantly")
            }

            Section {
                Button {
                    newEmoji = ""
                    newText = ""
                    showAddSheet = true
                } label: {
                    Label(lang == "fr" ? "Ajouter une phrase" : "Add a phrase", systemImage: "plus.circle")
                }
            }

            Section {
                Button(role: .destructive) {
                    phrases = []
                    onChanged?(phrases)
                } label: {
                    HStack {
                        Spacer()
                        Text(lang == "fr" ? "Réinitialiser par défaut" : "Reset to defaults")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(lang == "fr" ? "Phrases rapides" : "Quick Phrases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                Form {
                    Section(lang == "fr" ? "Emoji" : "Emoji") {
                        TextField(lang == "fr" ? "Ex: 👋" : "E.g.: 👋", text: $newEmoji)
                            .font(.title)
                    }
                    Section(lang == "fr" ? "Phrase" : "Phrase") {
                        TextField(lang == "fr" ? "Ex: Bonjour" : "E.g.: Hello", text: $newText)
                    }
                }
                .navigationTitle(lang == "fr" ? "Nouvelle phrase" : "New phrase")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(lang == "fr" ? "Annuler" : "Cancel") { showAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(lang == "fr" ? "Ajouter" : "Add") {
                            let emoji = newEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                            let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            if phrases.isEmpty {
                                phrases = displayPhrases
                            }
                            phrases.append(QuickPhrase(emoji: emoji.isEmpty ? "💬" : emoji, text: text))
                            onChanged?(phrases)
                            showAddSheet = false
                        }
                        .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func deletePhrase(at offsets: IndexSet) {
        if phrases.isEmpty {
            phrases = displayPhrases
        }
        phrases.remove(atOffsets: offsets)
        onChanged?(phrases)
    }

    private func movePhrase(from source: IndexSet, to destination: Int) {
        if phrases.isEmpty {
            phrases = displayPhrases
        }
        phrases.move(fromOffsets: source, toOffset: destination)
        onChanged?(phrases)
    }
}

// MARK: - Privacy Policy View

struct PrivacyPolicyNativeView: View {
    @ObservedObject private var vm = SettingsViewModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if vm.lang == "fr" {
                    LegalDate("Derniere mise a jour : mars 2026")
                    LegalParagraph("Talkie est une application d\u{2019}aide a la communication pour les personnes vivant avec la SLA, les personnes muettes ou ayant des difficultes a parler. Votre vie privee est notre priorite.")
                    LegalHeading("Donnees collectees")
                    LegalBullet("Nom d\u{2019}utilisateur", detail: "stocke uniquement sur votre appareil, utilise pour personnaliser les suggestions.")
                    LegalBullet("Transcriptions de conversations", detail: "stockees uniquement sur votre appareil (20 derniers echanges maximum). Jamais transmises a un serveur externe.")
                    LegalBullet("Memoire du patient", detail: "notes personnelles stockees localement, utilisees pour contextualiser les suggestions IA.")
                    LegalBullet("Cle API ElevenLabs", detail: "fournie par l\u{2019}utilisateur, stockee de maniere securisee dans le trousseau iOS (Keychain). Utilisee uniquement pour les appels a l\u{2019}API ElevenLabs.")
                    LegalBullet("Echantillons vocaux", detail: "stockes localement. Envoyes a ElevenLabs uniquement lors du clonage vocal, a l\u{2019}initiative de l\u{2019}utilisateur.")
                    LegalHeading("Services tiers")
                    LegalBullet("ElevenLabs (optionnel)", detail: "synthese vocale et clonage de voix. Lorsque vous activez cette fonctionnalite, votre consentement explicite est requis. Le texte a prononcer et/ou les echantillons vocaux sont envoyes aux serveurs d\u{2019}ElevenLabs. Aucune donnee n\u{2019}est conservee par Talkie.")
                    LegalBullet("Apple Intelligence (iOS 26+)", detail: "generation de suggestions de reponse. Le traitement est effectue entierement sur votre appareil. Aucune donnee ne quitte votre iPhone/iPad.")
                    LegalHeading("Ce que nous ne faisons PAS")
                    LegalBullet("Aucun serveur backend \u{2014} toutes les donnees restent sur votre appareil.")
                    LegalBullet("Aucune collecte d\u{2019}analytics ou de telemetrie.")
                    LegalBullet("Aucune publicite.")
                    LegalBullet("Aucun suivi d\u{2019}activite entre applications.")
                    LegalBullet("Aucune vente ou partage de donnees avec des tiers.")
                    LegalHeading("Microphone")
                    LegalParagraph("Talkie utilise le microphone pour la reconnaissance vocale. L\u{2019}audio est traite sur votre appareil et n\u{2019}est jamais enregistre ni transmis a un serveur externe.")
                    LegalHeading("Suppression des donnees")
                    LegalParagraph("Vous pouvez supprimer toutes vos donnees a tout moment depuis les reglages de l\u{2019}application (section \u{00AB} Donnees personnelles \u{00BB}). Cette action supprime l\u{2019}historique, la memoire, les echantillons vocaux et la cle API du trousseau.")
                    LegalHeading("Enfants")
                    LegalParagraph("Talkie n\u{2019}est pas destinee aux enfants de moins de 13 ans.")
                    LegalHeading("Contact")
                    LegalContact()
                } else {
                    LegalDate("Last updated: March 2026")
                    LegalParagraph("Talkie is a communication aid app for people living with ALS, people who are non-speaking, or who have difficulty speaking. Your privacy is our priority.")
                    LegalHeading("Data we collect")
                    LegalBullet("Username", detail: "stored only on your device, used to personalize suggestions.")
                    LegalBullet("Conversation transcripts", detail: "stored only on your device (last 20 exchanges maximum). Never sent to an external server.")
                    LegalBullet("Patient memory", detail: "personal notes stored locally, used to contextualize AI suggestions.")
                    LegalBullet("ElevenLabs API key", detail: "provided by you, stored securely in the iOS Keychain. Used only for ElevenLabs API calls.")
                    LegalBullet("Voice samples", detail: "stored locally. Sent to ElevenLabs only when you initiate voice cloning.")
                    LegalHeading("Third-party services")
                    LegalBullet("ElevenLabs (optional)", detail: "speech synthesis and voice cloning. When you enable this feature, your explicit consent is required. Text to speak and/or voice samples are sent to ElevenLabs servers. Talkie does not retain this data.")
                    LegalBullet("Apple Intelligence (iOS 26+)", detail: "response suggestions. Processing is done entirely on your device. No data leaves your iPhone or iPad.")
                    LegalHeading("What we do NOT do")
                    LegalBullet("No backend server \u{2014} all data stays on your device.")
                    LegalBullet("No analytics or telemetry.")
                    LegalBullet("No advertising.")
                    LegalBullet("No cross-app tracking.")
                    LegalBullet("No sale or sharing of data with third parties.")
                    LegalHeading("Microphone")
                    LegalParagraph("Talkie uses the microphone for speech recognition. Audio is processed on your device and is never recorded or sent to an external server.")
                    LegalHeading("Deleting your data")
                    LegalParagraph("You can delete all your data at any time from the app settings (Personal data section). This removes history, memory, voice samples, and the API key from the Keychain.")
                    LegalHeading("Children")
                    LegalParagraph("Talkie is not intended for children under 13.")
                    LegalHeading("Contact")
                    LegalContact()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle(vm.lang == "fr" ? "Confidentialite" : "Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Support View

struct SupportNativeView: View {
    @ObservedObject private var vm = SettingsViewModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if vm.lang == "fr" {
                    LegalDate("Application d\u{2019}aide a la communication")
                    LegalHeading("Besoin d\u{2019}aide ?")
                    LegalParagraph("Si vous rencontrez un probleme avec Talkie ou si vous avez une question, contactez-nous par email :")
                    LegalContact()
                    LegalHeading("Questions frequentes")
                    LegalSubheading("Comment configurer la voix clonee ?")
                    LegalParagraph("Creez un compte sur ElevenLabs, recuperez votre cle API, puis entrez-la dans les reglages de l\u{2019}application. Vous pouvez ensuite enregistrer des echantillons vocaux et cloner la voix.")
                    LegalSubheading("Les suggestions IA ne fonctionnent pas")
                    LegalParagraph("Les suggestions IA necessitent iOS 26 ou ulterieur avec Apple Intelligence active. Sur les versions anterieures, utilisez le mode saisie manuelle (bouton clavier).")
                    LegalSubheading("Comment supprimer mes donnees ?")
                    LegalParagraph("Ouvrez les reglages de l\u{2019}application, section \u{00AB} Donnees personnelles \u{00BB}, puis appuyez sur \u{00AB} Supprimer toutes mes donnees \u{00BB}.")
                    LegalHeading("Signaler un probleme")
                    LegalParagraph("Si vous constatez un comportement inapproprie des suggestions IA ou tout autre probleme, envoyez-nous un email en decrivant le probleme.")
                    LegalContact()
                } else {
                    LegalDate("Communication aid app")
                    LegalHeading("Need help?")
                    LegalParagraph("If you have a problem with Talkie or a question, contact us by email:")
                    LegalContact()
                    LegalHeading("Frequently asked questions")
                    LegalSubheading("How do I set up cloned voice?")
                    LegalParagraph("Create an account on ElevenLabs, get your API key, then enter it in the app settings. You can then record voice samples and clone your voice.")
                    LegalSubheading("AI suggestions don\u{2019}t work")
                    LegalParagraph("AI suggestions require iOS 26 or later with Apple Intelligence enabled. On earlier versions, use manual input (keyboard button).")
                    LegalSubheading("How do I delete my data?")
                    LegalParagraph("Open app settings, go to the Personal data section, then tap Delete all my data.")
                    LegalHeading("Report an issue")
                    LegalParagraph("If you notice inappropriate AI suggestions or any other problem, email us with a short description.")
                    LegalContact()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Legal Helper Views

private struct LegalHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}

private struct LegalSubheading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

private struct LegalParagraph: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
    }
}

private struct LegalDate: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 12)
    }
}

private struct LegalBullet: View {
    let title: String
    let detail: String?
    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .foregroundStyle(.secondary)
            if let detail {
                (Text(title).fontWeight(.semibold) + Text(" \u{2014} " + detail))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 6)
    }
}

private struct LegalContact: View {
    var body: some View {
        Button {
            if let url = URL(string: "mailto:samuelgracio@gmail.com") {
                UIApplication.shared.open(url)
            }
        } label: {
            Text("samuelgracio@gmail.com")
                .font(.subheadline)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Report View

struct ReportNativeView: View {
    @State private var reportText = ""
    @ObservedObject private var vm = SettingsViewModel.shared

    var body: some View {
        Form {
            Section {
                TextEditor(text: $reportText)
                    .frame(minHeight: 150)
            } header: {
                Text(vm.lang == "fr"
                    ? "Bug, contenu inapproprié, ou suggestion d'amélioration"
                    : "Bug, inappropriate content, or improvement suggestion")
            }

            Section {
                Button(vm.lang == "fr" ? "Envoyer par e-mail" : "Send by email") {
                    sendReport()
                }
                .disabled(reportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text(vm.lang == "fr"
                    ? "Un e-mail sera préparé avec votre description. Vous pourrez le vérifier avant envoi."
                    : "An email will be prepared with your message. You can review it before sending.")
            }
        }
        .navigationTitle(vm.lang == "fr" ? "Signaler" : "Report")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendReport() {
        let subjectRaw = vm.lang == "fr" ? "Talkie - Signalement" : "Talkie - Report"
        let subject = subjectRaw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2.0"
        let body = (reportText + "\n\n---\nVersion: v\(version)").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:samuelgracio@gmail.com?subject=\(subject)&body=\(body)") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Helper Views
