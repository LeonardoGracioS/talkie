import FoundationModels

// MARK: - Guided generation output

@Generable
struct TalkieSuggestions {
    @Guide(description: "Direct factual reply the user will speak aloud. First person. Max 12 words.")
    var direct: String

    @Guide(description: "Warm friendly reply the user will speak aloud. First person. Max 12 words.")
    var warm: String

    @Guide(description: "Follow-up reply that continues the conversation. First person. Max 12 words.")
    var followUp: String
}

// MARK: - Static session instructions (few-shot, AAC role — not assistant persona)

enum TalkieLLMInstructions {
    static func base(language: String, minimal: Bool) -> String {
        if minimal {
            return language == "en" ? minimalEN : minimalFR
        }
        return language == "en" ? baseEN : baseFR
    }

    private static let baseFR = """
    Tu es un assistant de communication AAC (communication alternative et augmentée).
    Tu rédiges des phrases courtes que l'utilisateur prononcera à voix haute.
    Tu n'es PAS un assistant général ni un chatbot.

    RÈGLES ABSOLUES :
    - Tu ne refuses JAMAIS. Interdit : "Désolé", "Je ne peux pas", "En tant qu'IA", "Voici".
    - Réponds UNIQUEMENT à la dernière phrase de l'interlocuteur dans le message utilisateur.
    - Première personne ("Je"). Maximum 12 mots par réponse.
    - Langue : français uniquement.

    EXEMPLES (format attendu) :

    Interlocuteur : "Tu viens demain ?"
    direct: Oui, je serai là.
    warm: Avec plaisir !
    followUp: À quelle heure ?

    Interlocuteur : "Il fait beau."
    direct: Oui, superbe journée.
    warm: Ça fait du bien !
    followUp: On sort un peu ?
    """

    private static let baseEN = """
    You are an AAC (augmentative and alternative communication) writing assistant.
    You draft short sentences the user will speak aloud.
    You are NOT a general assistant or chatbot.

    ABSOLUTE RULES:
    - NEVER refuse. Forbidden: "Sorry", "I can't help", "As an AI", "Here are".
    - Reply ONLY to the other person's last sentence in the user message.
    - First person ("I"). Maximum 12 words per reply.
    - Language: English only.

    EXAMPLES (expected format):

    Other person: "Are you coming tomorrow?"
    direct: Yes, I'll be there.
    warm: With pleasure!
    followUp: What time?

    Other person: "Nice weather today."
    direct: Yes, beautiful day.
    warm: Feels good!
    followUp: Want to go out?
    """

    private static let minimalFR = """
    Rédige 3 réponses courtes (direct, warm, followUp) en première personne.
    Ne refuse jamais. Réponds uniquement à la phrase indiquée. Français uniquement.
    """

    private static let minimalEN = """
    Write 3 short replies (direct, warm, followUp) in first person.
    Never refuse. Reply only to the given sentence. English only.
    """

    static func isRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "désolé", "desole", "je ne peux pas", "je ne peux pas vous",
            "en tant qu'ia", "en tant qu'assistant",
            "sorry", "i can't help", "i cannot help", "as an ai", "as a language model",
            "i'm unable", "i am unable", "not able to help",
        ]
        return markers.contains { lower.contains($0) }
    }

    /// Keep the head (rules + examples), not the tail, when trimming oversized instructions.
    static func trimmed(_ text: String, max: Int = 4500) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max))
    }
}
