import Testing
@testable import GobiModel

struct LiveSettingsTests {
    @Test func terminalGainsScrollbackAndStartFolder() {
        var s = TerminalSettings()
        #expect(s.scrollback == 10_000)
        #expect(s.startIn == .project)
        s.scrollback = 50_000
        s.startIn = .home
        s.copyOnSelect = true
        #expect(TerminalSettings.decodeOrDefault(s.encoded()) == s)
        s.scrollback = 12_000
        #expect(s.validated().scrollback == 10_000)
        s.scrollback = 1_000_000
        #expect(s.validated().scrollback == 50_000)
        #expect(TerminalSettings.decodeOrDefault("startIn=nowhere").startIn == .project)
    }

    @Test func terminalStartFolderIsChosenFromTheSetting() {
        #expect(TerminalSettings.StartFolder.project.folder(project: "/work/p", home: "/Users/me") == "/work/p")
        #expect(TerminalSettings.StartFolder.home.folder(project: "/work/p", home: "/Users/me") == "/Users/me")
        #expect(TerminalSettings.StartFolder.home.folder(project: "/work/p", home: "") == "/work/p")
    }

    @Test func oldStoredSettingsKeepWorking() {
        let old = "fontSize=14\ncursor=bar\nblink=false\noptionAsMeta=true\nbell=off"
        let s = TerminalSettings.decodeOrDefault(old)
        #expect(s.fontSize == 14 && s.scrollback == 10_000 && s.startIn == .project)
    }

    @Test func generalGainsQuitConfirmation() {
        var s = GeneralSettings()
        #expect(s.confirmQuit)
        s.confirmQuit = false
        #expect(GeneralSettings.decodeOrDefault(s.encoded()) == s)
        #expect(GeneralSettings.decodeOrDefault("onLaunch=welcome").confirmQuit)
    }

    @Test func quitMessageNamesWhatWouldBeLost() {
        #expect(QuitConfirmation.message(unsavedFiles: 0, runningTasks: 0, enabled: true) == nil)
        #expect(QuitConfirmation.message(unsavedFiles: 2, runningTasks: 0, enabled: false) == nil)
        #expect(QuitConfirmation.message(unsavedFiles: 1, runningTasks: 0, enabled: true) == "1 file has unsaved changes.")
        #expect(QuitConfirmation.message(unsavedFiles: 3, runningTasks: 0, enabled: true) == "3 files have unsaved changes.")
        #expect(QuitConfirmation.message(unsavedFiles: 0, runningTasks: 1, enabled: true) == "1 run or debug session is still going.")
        #expect(QuitConfirmation.message(unsavedFiles: 2, runningTasks: 2, enabled: true) == "2 files have unsaved changes. 2 runs or debug sessions are still going.")
    }

    @Test func gitGainsPathAndFetchInterval() {
        var s = GitSettings()
        #expect(s.gitPath == "" && s.fetchMinutes == 0)
        s.gitPath = "/opt/homebrew/bin/git"
        s.fetchMinutes = 10
        #expect(GitSettings.decodeOrDefault(s.encoded()) == s)
        #expect(GitSettings.decodeOrDefault("fetchMinutes=7").fetchMinutes == 5)
        #expect(GitSettings.decodeOrDefault("gitPath=relative/git").gitPath == "")
        #expect(GitSettings.decodeOrDefault("showColours=false").fetchMinutes == 0)
    }

    @Test func toolPathMustBeEmptyOrAbsolute() {
        #expect(ToolPath.clean("") == "")
        #expect(ToolPath.clean("  /usr/bin/git  ") == "/usr/bin/git")
        #expect(ToolPath.clean("git") == "")
        #expect(ToolPath.clean("/a\nb") == "")
    }

    @Test func advancedSettingsHoldGoplsPathAndLineLimit() {
        var s = AdvancedSettings()
        #expect(s.goplsPath == "" && s.lineLimit == 550_000)
        s.goplsPath = "/Users/me/go/bin/gopls"
        s.lineLimit = 100_000
        #expect(AdvancedSettings.decodeOrDefault(s.encoded()) == s)
        #expect(AdvancedSettings.decodeOrDefault("lineLimit=120000").lineLimit == 100_000)
        #expect(AdvancedSettings.decodeOrDefault("lineLimit=9").lineLimit == 100_000)
        #expect(AdvancedSettings.decodeOrDefault("").lineLimit == 550_000)
        #expect(AdvancedSettings.lineLimitTitle(550_000) == "550,000 characters")
        #expect(AdvancedSettings.lineLimitTitle(100_000) == "100,000 characters")
    }

    @Test func fetchTimerFiresOnlyWhenDue() {
        #expect(!AutoFetch.isDue(minutes: 0, secondsSinceLast: 10_000))
        #expect(!AutoFetch.isDue(minutes: 5, secondsSinceLast: 299))
        #expect(AutoFetch.isDue(minutes: 5, secondsSinceLast: 300))
        #expect(AutoFetch.isDue(minutes: 30, secondsSinceLast: 1_800))
    }
}
