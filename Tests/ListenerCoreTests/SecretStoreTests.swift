import Foundation
import Testing

@testable import ListenerCore

struct DotEnvTests {
    @Test func plainValues() {
        let values = DotEnv.parse("ANTHROPIC_API_KEY=sk-ant-123\nOTHER = two words \n")
        #expect(values == ["ANTHROPIC_API_KEY": "sk-ant-123", "OTHER": "two words"])
    }

    @Test func commentsAndBlankLinesAreSkipped() {
        let text = """
            # Listener secrets

              # indented comment
            KEY=value # trailing comment
            HASH=pa#ss
            """
        #expect(DotEnv.parse(text) == ["KEY": "value", "HASH": "pa#ss"])
    }

    @Test func exportPrefixIsIgnored() {
        #expect(DotEnv.parse("export KEY=value\nexport  SPACED=x") == ["KEY": "value", "SPACED": "x"])
    }

    @Test func singleQuotesAreLiteral() {
        #expect(DotEnv.parse(#"KEY='a # b \n c' # comment"#) == ["KEY": #"a # b \n c"#])
    }

    @Test func doubleQuotesUnderstandEscapes() {
        #expect(
            DotEnv.parse(#"KEY="line\none \"quoted\" back\\slash" # comment"#) == [
                "KEY": "line\none \"quoted\" back\\slash"
            ])
    }

    @Test func equalsSignsInsideValuesAreKept() {
        #expect(
            DotEnv.parse("TOKEN=abc==\nURL=https://x.test/?a=b") == ["TOKEN": "abc==", "URL": "https://x.test/?a=b"])
    }

    @Test func emptyValuesAndWindowsLineEndings() {
        #expect(DotEnv.parse("EMPTY=\r\nKEY=value\r\n") == ["EMPTY": "", "KEY": "value"])
    }

    @Test func malformedLinesAreSkipped() {
        let text = """
            no equals sign
            =no key
            1KEY=starts with a digit
            BAD KEY=space in key
            OPEN="never closed
            OPEN2='never closed
            GOOD=yes
            """
        #expect(DotEnv.parse(text) == ["GOOD": "yes"])
    }

    @Test func laterLinesWin() {
        #expect(DotEnv.parse("KEY=first\nKEY=second") == ["KEY": "second"])
    }
}

struct SecretStoreTests {
    @Test func environmentStoreTrimsAndIgnoresEmptyValues() {
        #expect(EnvironmentSecretStore(environment: ["ANTHROPIC_API_KEY": " sk \n"]).secret(.anthropicAPIKey) == "sk")
        #expect(EnvironmentSecretStore(environment: ["ANTHROPIC_API_KEY": "  "]).secret(.anthropicAPIKey) == nil)
        #expect(EnvironmentSecretStore(environment: [:]).secret(.anthropicAPIKey) == nil)
    }

    @Test func dotEnvStoreReadsTheFileOnEveryLookup() throws {
        let file = temporaryFile(".env")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = DotEnvSecretStore(file: file)
        #expect(store.secret(.anthropicAPIKey) == nil)

        try Data("ANTHROPIC_API_KEY=\"sk-ant-file\"\n".utf8).write(to: file)
        #expect(store.secret(.anthropicAPIKey) == "sk-ant-file")
    }

    @Test func chainReturnsTheFirstStoreThatHasTheSecret() {
        let chain = ChainedSecretStore([
            .init(name: "Keychain", store: EnvironmentSecretStore(environment: [:])),
            .init(name: "Environment", store: EnvironmentSecretStore(environment: ["ANTHROPIC_API_KEY": "from-env"])),
            .init(name: ".env", store: EnvironmentSecretStore(environment: ["ANTHROPIC_API_KEY": "from-file"])),
        ])
        #expect(chain.secret(.anthropicAPIKey) == "from-env")
        #expect(chain.lookup(.anthropicAPIKey)?.source == "Environment")
        #expect(ChainedSecretStore([]).lookup(.anthropicAPIKey) == nil)
    }
}
