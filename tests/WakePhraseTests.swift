import Foundation

// MARK: - WakePhrase tests (pure functions, no concurrency)

@main
enum WakePhraseTests {

    static var failures = 0

    static func main() {
        // MARK: split — Jarvis is the wake word; «OK Coucou» only with the Settings option
        checkJarvis("Jarvis alone",          WakePhrase.split("Jarvis"),                 cmd: "",              jarvis: true)
        checkJarvis("hey Jarvis, abre Figma",
                    WakePhrase.split("hey Jarvis, abre Figma"),                 cmd: "abre Figma",    jarvis: true)
        checkJarvis("OK Jarvis, ¿qué hora es?",
                    WakePhrase.split("OK Jarvis, ¿qué hora es?"),               cmd: "qué hora es?",  jarvis: true)
        checkNoMatch("ok coucou off by default",        WakePhrase.split("ok coucou"))
        checkNoMatch("OK Coucou command off by default",
                     WakePhrase.split("OK Coucou, mets l'album de Daft Punk"))
        checkNoMatch("hey cou cou off by default",      WakePhrase.split("hey cou cou ouvre figma"))
        checkJarvis("coucou option off: only Jarvis wakes",
                    WakePhrase.split("jarvis no ok coucou ajoute GitHub"),      cmd: "no ok coucou ajoute GitHub", jarvis: true)
        checkJarvis("coucou option on: Jarvis still wakes",
                    WakePhrase.split("Jarvis pon música", coucou: true),        cmd: "pon música",    jarvis: true)

        // MARK: split — should match (with «Responder también a Coucou» on)

        // Basic wake phrases (no command)
        checkMatch("ok coucou",              WakePhrase.split("ok coucou", coucou: true),              cmd: "")
        checkMatch("OK COUCOU",              WakePhrase.split("OK COUCOU", coucou: true),              cmd: "")
        checkMatch("okay coucou",            WakePhrase.split("okay coucou", coucou: true),            cmd: "")
        checkMatch("ok kuku",                WakePhrase.split("ok kuku", coucou: true),                cmd: "")
        checkMatch("ok cou cou",             WakePhrase.split("ok cou cou", coucou: true),             cmd: "")
        checkMatch("hey coucou",             WakePhrase.split("hey coucou", coucou: true),             cmd: "")
        checkMatch("Hey Coucou",             WakePhrase.split("Hey Coucou", coucou: true),             cmd: "")

        // Command extracted from original text (casing/punctuation preserved)
        checkMatch("Okay, Coucou, ajoute GitHub",
                   WakePhrase.split("Okay, Coucou, ajoute GitHub", coucou: true),             cmd: "ajoute GitHub")
        checkMatch("ok cuckoo add github",
                   WakePhrase.split("ok cuckoo add github", coucou: true),                    cmd: "add github")
        checkMatch("ok coucou ouvre figma",
                   WakePhrase.split("ok coucou ouvre figma", coucou: true),                   cmd: "ouvre figma")

        // Apostrophes, hyphens and accents preserved in command
        checkMatch("OK Coucou, mets l'album de Daft Punk",
                   WakePhrase.split("OK Coucou, mets l'album de Daft Punk", coucou: true),   cmd: "mets l'album de Daft Punk")
        checkMatch("ok coucou qu'est-ce que fait Claude ?",
                   WakePhrase.split("ok coucou qu'est-ce que fait Claude ?", coucou: true),  cmd: "qu'est-ce que fait Claude ?")

        // Wake anywhere in transcript (word-boundary search)
        checkMatch("euh ok coucou mets de la musique",
                   WakePhrase.split("euh ok coucou mets de la musique", coucou: true),        cmd: "mets de la musique")
        checkMatch("la chanson dit ok coucou",
                   WakePhrase.split("la chanson dit ok coucou", coucou: true),                cmd: "") // accepted false positive

        // LAST occurrence wins
        checkMatch("ok coucou search ok coucou play music",
                   WakePhrase.split("ok coucou search ok coucou play music", coucou: true),   cmd: "play music")

        // Partial word-by-word delivery
        checkNoMatch("ok alone",             WakePhrase.split("ok"))
        checkMatch("ok coucou partial",      WakePhrase.split("ok coucou", coucou: true),              cmd: "")
        checkMatch("ok coucou with more",    WakePhrase.split("ok coucou mets", coucou: true),         cmd: "mets")

        // "Jarvis" (this fork): alone or after ok/hey/oye, flagged as such
        checkJarvis("Jarvis, ¿cómo va HispanoHost?",
                    WakePhrase.split("Jarvis, ¿cómo va HispanoHost?"),          cmd: "cómo va HispanoHost?", jarvis: true)
        checkJarvis("oye Jarvis pide el informe",
                    WakePhrase.split("oye Jarvis pide el informe"),             cmd: "pide el informe", jarvis: true)
        checkJarvis("ok jarvis alone",       WakePhrase.split("ok jarvis"),              cmd: "",              jarvis: true)
        checkJarvis("Yarvis dictated",       WakePhrase.split("Yarvis qué tal"),         cmd: "qué tal",       jarvis: true)
        checkJarvis("ok coucou not jarvis",  WakePhrase.split("ok coucou mets", coucou: true),         cmd: "mets",          jarvis: false)
        checkJarvis("last wake wins (coucou)",
                    WakePhrase.split("jarvis no ok coucou ajoute GitHub", coucou: true),      cmd: "ajoute GitHub", jarvis: false)
        checkNoMatch("jarvisito",            WakePhrase.split("jarvisito"))

        // MARK: split — should NOT match
        checkNoMatch("standalone coucou",    WakePhrase.split("coucou", coucou: true))
        checkNoMatch("standalone COUCOU",    WakePhrase.split("COUCOU", coucou: true))
        checkNoMatch("partial coucou ça va", WakePhrase.split("coucou ça va", coucou: true))
        checkNoMatch("coucou comment",       WakePhrase.split("coucou comment tu vas", coucou: true))
        checkNoMatch("ok google",            WakePhrase.split("ok google"))
        checkNoMatch("hey siri",             WakePhrase.split("hey siri"))
        checkNoMatch("okkkk coucou",         WakePhrase.split("okkkk coucou", coucou: true))
        checkNoMatch("empty",                WakePhrase.split(""))

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }

    static var total = 0

    static func checkMatch(_ label: String, _ r: WakePhrase.SplitResult, cmd: String) {
        total += 1
        if !r.matched {
            print("✗  \(label) — expected match, got no match"); failures += 1; return
        }
        if r.command != cmd {
            print("✗  \(label) — matched ✓ but command \"\(r.command)\" ≠ \"\(cmd)\""); failures += 1; return
        }
        print("✓  \(label)")
    }

    static func checkJarvis(_ label: String, _ r: WakePhrase.SplitResult, cmd: String, jarvis: Bool) {
        if r.matched && r.jarvis != jarvis {
            total += 1
            print("✗  \(label) — jarvis \(r.jarvis) ≠ \(jarvis)"); failures += 1; return
        }
        checkMatch(label, r, cmd: cmd)
    }

    static func checkNoMatch(_ label: String, _ r: WakePhrase.SplitResult) {
        total += 1
        if r.matched { print("✗  \(label) — expected no match, got matched (cmd: \"\(r.command)\")"); failures += 1 }
        else         { print("✓  \(label)") }
    }
}
