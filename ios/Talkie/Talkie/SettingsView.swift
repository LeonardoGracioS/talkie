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
            .sheet(isPresented: $showELConsent) {
                ElevenLabsConsentView(lang: vm.lang) {
                    vm.hasELConsent = true
                    vm.useElevenLabs = true
                    showELConsent = false
                } onDecline: {
                    showELConsent = false
                }
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
                    LegalDate("Derniere mise a jour : avril 2026")
                    LegalParagraph("Talkie est une application d\u{2019}aide a la communication pour les personnes vivant avec la SLA, les personnes muettes ou ayant des difficultes a parler. Votre vie privee est notre priorite.")

                    LegalHeading("1. Donnees collectees et methodes de collecte")
                    LegalBullet("Nom d\u{2019}utilisateur", detail: "saisi par l\u{2019}utilisateur lors de la configuration. Stocke uniquement sur votre appareil (localStorage), utilise pour personnaliser les suggestions IA.")
                    LegalBullet("Transcriptions de conversations", detail: "generees automatiquement par la reconnaissance vocale sur l\u{2019}appareil. Stockees uniquement sur votre appareil (localStorage, 20 derniers echanges maximum). Jamais transmises a un serveur externe.")
                    LegalBullet("Memoire du patient", detail: "notes personnelles saisies manuellement par l\u{2019}utilisateur. Stockees localement (localStorage), utilisees pour contextualiser les suggestions IA.")
                    LegalBullet("Memoire apprise", detail: "informations extraites automatiquement de vos conversations par le modele IA sur l\u{2019}appareil. Stockees localement. Vous pouvez les consulter, modifier ou supprimer a tout moment.")
                    LegalBullet("Cle API ElevenLabs", detail: "fournie volontairement par l\u{2019}utilisateur dans les reglages avances. Stockee de maniere securisee dans le trousseau iOS (Keychain).")
                    LegalBullet("Echantillons vocaux", detail: "enregistres par l\u{2019}utilisateur via le microphone ou importes. Stockes localement. Envoyes a ElevenLabs uniquement lors du clonage vocal, apres consentement explicite.")
                    LegalBullet("Donnees audio (microphone)", detail: "captees en temps reel pour la reconnaissance vocale. Traitees sur l\u{2019}appareil, jamais enregistrees ni transmises.")

                    LegalHeading("2. Utilisation des donnees")
                    LegalBullet("Nom d\u{2019}utilisateur", detail: "personnalisation des reponses IA generees sur l\u{2019}appareil.")
                    LegalBullet("Transcriptions et memoire", detail: "fournir un contexte conversationnel au modele IA sur l\u{2019}appareil (Apple Intelligence) pour generer des suggestions pertinentes.")
                    LegalBullet("Cle API ElevenLabs", detail: "authentifier les requetes de synthese vocale et de clonage vocal aupres d\u{2019}ElevenLabs.")
                    LegalBullet("Texte des messages", detail: "lorsque ElevenLabs est active, le texte a prononcer est envoye aux serveurs d\u{2019}ElevenLabs pour la synthese vocale.")
                    LegalBullet("Echantillons vocaux", detail: "lorsque le clonage vocal est initie, les echantillons audio sont envoyes aux serveurs d\u{2019}ElevenLabs pour creer une voix clonee.")
                    LegalBullet("Donnees audio du microphone", detail: "transcription de la parole en texte, traitee localement sur l\u{2019}appareil.")

                    LegalHeading("3. Partage avec des tiers")
                    LegalSubheading("ElevenLabs, Inc. (optionnel)")
                    LegalParagraph("ElevenLabs est le seul service tiers avec lequel des donnees personnelles peuvent etre partagees. Ce partage est entierement optionnel et necessite l\u{2019}activation manuelle par l\u{2019}utilisateur et son consentement explicite avant tout envoi de donnees.")
                    LegalParagraph("Donnees partagees : le texte des messages a prononcer (synthese vocale) et les echantillons audio de votre voix (clonage vocal). Talkie ne conserve aucune copie des donnees envoyees. ElevenLabs traite ces donnees conformement a sa politique de confidentialite, qui prevoit des protections equivalentes.")
                    LegalSubheading("Apple Intelligence (iOS 26+)")
                    LegalParagraph("Les suggestions de reponse sont generees entierement sur votre appareil. Aucune donnee ne quitte votre iPhone/iPad. Apple n\u{2019}a pas acces a vos conversations.")
                    LegalParagraph("En dehors d\u{2019}ElevenLabs (si active), Talkie ne partage, ne vend et ne transmet aucune donnee personnelle a quelque tiers que ce soit.")

                    LegalHeading("4. Donnees biometriques et faciales")
                    LegalParagraph("Talkie n\u{2019}accede pas a la camera de votre appareil et ne collecte aucune donnee faciale ni donnee d\u{2019}identification biometrique faciale. L\u{2019}application n\u{2019}utilise ni ARKit, ni la camera TrueDepth, ni le framework Vision, ni aucune technologie de reconnaissance ou de suivi facial. Les seules donnees biometriques potentiellement traitees sont les echantillons vocaux envoyes a ElevenLabs pour le clonage vocal, uniquement avec votre consentement explicite.")

                    LegalHeading("5. Conservation des donnees")
                    LegalBullet("Nom d\u{2019}utilisateur", detail: "conserve sur l\u{2019}appareil jusqu\u{2019}a suppression manuelle.")
                    LegalBullet("Transcriptions", detail: "les 20 derniers echanges sont conserves. Les plus anciens sont automatiquement supprimes.")
                    LegalBullet("Memoire du patient et memoire apprise", detail: "conservees jusqu\u{2019}a suppression manuelle.")
                    LegalBullet("Cle API ElevenLabs", detail: "conservee dans le trousseau iOS jusqu\u{2019}a suppression manuelle.")
                    LegalBullet("Echantillons vocaux", detail: "conserves localement jusqu\u{2019}a suppression manuelle. Lors de l\u{2019}envoi a ElevenLabs, les donnees sont traitees selon leur politique de conservation.")
                    LegalBullet("Donnees audio du microphone", detail: "traitees en temps reel et non enregistrees. Aucune conservation.")

                    LegalHeading("6. Ce que nous ne faisons PAS")
                    LegalBullet("Aucun serveur backend \u{2014} toutes les donnees restent sur votre appareil (sauf envoi optionnel a ElevenLabs).")
                    LegalBullet("Aucune collecte d\u{2019}analytics ou de telemetrie.")
                    LegalBullet("Aucune publicite.")
                    LegalBullet("Aucun suivi d\u{2019}activite entre applications.")
                    LegalBullet("Aucune vente ou partage de donnees avec des tiers (hors ElevenLabs si active).")
                    LegalBullet("Aucun acces a la camera ni collecte de donnees faciales.")

                    LegalHeading("7. Microphone")
                    LegalParagraph("Talkie utilise le microphone exclusivement pour la reconnaissance vocale. L\u{2019}audio est traite sur votre appareil en temps reel et n\u{2019}est jamais enregistre, stocke ni transmis a un serveur externe.")

                    LegalHeading("8. Suppression des donnees")
                    LegalParagraph("Vous pouvez supprimer toutes vos donnees a tout moment depuis les reglages de l\u{2019}application. Cette action supprime l\u{2019}historique, la memoire, les echantillons vocaux et la cle API du trousseau. La suppression est immediate et irreversible.")

                    LegalHeading("9. Enfants")
                    LegalParagraph("Talkie n\u{2019}est pas destinee aux enfants de moins de 13 ans.")
                    LegalHeading("Contact")
                    LegalContact()
                } else {
                    LegalDate("Last updated: April 2026")
                    LegalParagraph("Talkie is a communication aid app for people living with ALS, people who are non-speaking, or who have difficulty speaking. Your privacy is our priority.")

                    LegalHeading("1. Data We Collect and How We Collect It")
                    LegalBullet("Username", detail: "entered by the user during setup. Stored only on your device (localStorage), used to personalize AI suggestions.")
                    LegalBullet("Conversation transcripts", detail: "automatically generated by on-device speech recognition. Stored only on your device (localStorage, last 20 exchanges maximum). Never sent to an external server.")
                    LegalBullet("Patient memory", detail: "personal notes manually entered by the user. Stored locally (localStorage), used to contextualize AI suggestions.")
                    LegalBullet("Learned memory", detail: "information automatically extracted from your conversations by the on-device AI model. Stored locally. You can view, edit, or delete it at any time.")
                    LegalBullet("ElevenLabs API key", detail: "voluntarily provided by the user in advanced settings. Stored securely in the iOS Keychain.")
                    LegalBullet("Voice samples", detail: "recorded by the user via the microphone or imported. Stored locally. Sent to ElevenLabs only when the user explicitly initiates voice cloning, after consent.")
                    LegalBullet("Microphone audio data", detail: "captured in real time for speech recognition. Processed on-device, never recorded or transmitted.")

                    LegalHeading("2. How We Use Your Data")
                    LegalBullet("Username", detail: "personalizing AI responses generated on-device.")
                    LegalBullet("Transcripts and memory", detail: "providing conversational context to the on-device AI model (Apple Intelligence) for relevant response suggestions.")
                    LegalBullet("ElevenLabs API key", detail: "authenticating text-to-speech and voice cloning requests with ElevenLabs.")
                    LegalBullet("Message text", detail: "when ElevenLabs is enabled, text to be spoken is sent to ElevenLabs servers for speech synthesis.")
                    LegalBullet("Voice samples", detail: "when voice cloning is initiated, audio samples are sent to ElevenLabs servers to create a cloned voice.")
                    LegalBullet("Microphone audio data", detail: "on-device speech-to-text transcription.")

                    LegalHeading("3. Third-Party Data Sharing")
                    LegalSubheading("ElevenLabs, Inc. (optional)")
                    LegalParagraph("ElevenLabs is the only third-party service with which personal data may be shared. This sharing is entirely optional and requires manual activation by the user and explicit consent before any data is sent.")
                    LegalParagraph("Data shared: the text of messages to be spoken (text-to-speech) and audio samples of your voice (voice cloning). Talkie does not retain any copy of data sent. ElevenLabs processes this data in accordance with its privacy policy, which provides equivalent protections.")
                    LegalSubheading("Apple Intelligence (iOS 26+)")
                    LegalParagraph("Response suggestions are generated entirely on your device. No data leaves your iPhone/iPad. Apple does not have access to your conversations.")
                    LegalParagraph("Apart from ElevenLabs (if enabled), Talkie does not share, sell, or transmit any personal data to any third party.")

                    LegalHeading("4. Biometric and Facial Data")
                    LegalParagraph("Talkie does not access your device\u{2019}s camera and does not collect any facial data or facial biometric identification data. The app does not use ARKit, the TrueDepth camera, the Vision framework, or any facial recognition or tracking technology. The only biometric data potentially processed are voice samples sent to ElevenLabs for voice cloning, only with your explicit consent.")

                    LegalHeading("5. Data Retention")
                    LegalBullet("Username", detail: "retained on-device until manually deleted.")
                    LegalBullet("Conversation transcripts", detail: "the last 20 exchanges are retained. Older exchanges are automatically deleted.")
                    LegalBullet("Patient memory and learned memory", detail: "retained until manually deleted.")
                    LegalBullet("ElevenLabs API key", detail: "retained in the iOS Keychain until manually deleted.")
                    LegalBullet("Voice samples", detail: "retained locally until manually deleted. When sent to ElevenLabs, data is handled according to their retention policy.")
                    LegalBullet("Microphone audio data", detail: "processed in real time and not recorded. No retention.")

                    LegalHeading("6. What We Do NOT Do")
                    LegalBullet("No backend server \u{2014} all data stays on your device (except optional sharing with ElevenLabs).")
                    LegalBullet("No analytics or telemetry collection.")
                    LegalBullet("No advertising.")
                    LegalBullet("No cross-app tracking.")
                    LegalBullet("No sale or sharing of data with third parties (except ElevenLabs if enabled).")
                    LegalBullet("No camera access and no facial data collection.")

                    LegalHeading("7. Microphone")
                    LegalParagraph("Talkie uses the microphone exclusively for speech recognition. Audio is processed on your device in real time and is never recorded, stored, or transmitted to an external server.")

                    LegalHeading("8. Deleting Your Data")
                    LegalParagraph("You can delete all your data at any time from the app settings. This removes conversation history, memory, voice samples, and the API key from the iOS Keychain. Deletion is immediate and irreversible.")

                    LegalHeading("9. Children")
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

// MARK: - ElevenLabs Consent View

struct ElevenLabsConsentView: View {
    let lang: String
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    Text(lang == "fr" ? "Partage de donnees avec ElevenLabs" : "Data Sharing with ElevenLabs")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)

                    Text(lang == "fr"
                        ? "En activant ElevenLabs, certaines de vos donnees seront envoyees a un service tiers pour la synthese vocale. Veuillez lire attentivement les informations ci-dessous."
                        : "By enabling ElevenLabs, some of your data will be sent to a third-party service for speech synthesis. Please read the information below carefully.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            consentRow(
                                icon: "doc.text",
                                title: lang == "fr" ? "Donnees envoyees" : "Data sent",
                                detail: lang == "fr"
                                    ? "Le texte de vos messages (pour la synthese vocale) et vos echantillons audio (pour le clonage vocal)."
                                    : "The text of your messages (for text-to-speech) and your audio samples (for voice cloning)."
                            )
                            Divider()
                            consentRow(
                                icon: "building.2",
                                title: lang == "fr" ? "Destinataire" : "Recipient",
                                detail: lang == "fr"
                                    ? "ElevenLabs, Inc. \u{2014} service tiers de synthese vocale et de clonage de voix."
                                    : "ElevenLabs, Inc. \u{2014} third-party speech synthesis and voice cloning service."
                            )
                            Divider()
                            consentRow(
                                icon: "shield.checkered",
                                title: lang == "fr" ? "Protection" : "Protection",
                                detail: lang == "fr"
                                    ? "ElevenLabs traite vos donnees conformement a sa politique de confidentialite. Talkie ne conserve aucune copie des donnees envoyees."
                                    : "ElevenLabs processes your data according to its privacy policy. Talkie does not retain any copy of the data sent."
                            )
                            Divider()
                            consentRow(
                                icon: "hand.raised",
                                title: lang == "fr" ? "Votre controle" : "Your control",
                                detail: lang == "fr"
                                    ? "Vous pouvez desactiver ElevenLabs a tout moment dans les reglages. Aucune donnee ne sera envoyee tant que la fonctionnalite est desactivee."
                                    : "You can disable ElevenLabs at any time in settings. No data will be sent while the feature is disabled."
                            )
                        }
                    }

                    Button {
                        if let url = URL(string: "https://elevenlabs.io/privacy") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "link")
                            Text(lang == "fr" ? "Politique de confidentialite d\u{2019}ElevenLabs" : "ElevenLabs Privacy Policy")
                        }
                        .font(.subheadline)
                    }

                    VStack(spacing: 10) {
                        Button {
                            onAccept()
                        } label: {
                            Text(lang == "fr" ? "J\u{2019}accepte" : "I agree")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            onDecline()
                        } label: {
                            Text(lang == "fr" ? "Refuser" : "Decline")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("ElevenLabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang == "fr" ? "Fermer" : "Close") { onDecline() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func consentRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
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
