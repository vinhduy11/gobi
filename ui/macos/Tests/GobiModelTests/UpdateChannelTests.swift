import Testing
@testable import GobiModel

@Suite("Update channels")
struct UpdateChannelTests {
    @Test func aVersionWithAPreReleasePartIsOnThePrereleaseChannel() {
        for version in ["0.1.0-alpha.8", "0.1.0-beta.1", "1.0.0-rc.2", "0.2.0-alpha"] {
            #expect(UpdateChannel.channel(forVersion: version) == "prerelease", "\(version)")
        }
    }

    @Test func aPlainVersionIsOnTheDefaultChannel() {
        for version in ["0.1.0", "1.2.3", "10.0.0"] { #expect(UpdateChannel.channel(forVersion: version) == nil, "\(version)") }
    }

    @Test func sparkleIsToldWhichChannelsItMayOffer() {
        #expect(UpdateChannel.allowed(includePrereleases: true) == ["prerelease"])
        #expect(UpdateChannel.allowed(includePrereleases: false).isEmpty)
    }

    @Test func aPreReleaseBuildFollowsPreReleasesUnlessToldOtherwise() {
        var settings = GeneralSettings()
        #expect(settings.includesPrereleases(currentVersion: "0.1.0-alpha.8"))
        #expect(!settings.includesPrereleases(currentVersion: "0.1.0"))
        settings.includePrereleases = false
        #expect(!settings.includesPrereleases(currentVersion: "0.1.0-alpha.8"))
        settings.includePrereleases = true
        #expect(settings.includesPrereleases(currentVersion: "0.1.0"))
    }

    @Test func theChoiceIsStoredAndOldSettingsKeepTheDefault() {
        var settings = GeneralSettings()
        #expect(GeneralSettings.decodeOrDefault(settings.encoded()).includePrereleases == nil)
        settings.includePrereleases = false
        #expect(GeneralSettings.decodeOrDefault(settings.encoded()).includePrereleases == false)
        settings.includePrereleases = true
        #expect(GeneralSettings.decodeOrDefault(settings.encoded()).includePrereleases == true)
        #expect(GeneralSettings.decodeOrDefault("onLaunch=welcome\nrecentLimit=5\nconfirmQuit=false").includePrereleases == nil)
    }
}
