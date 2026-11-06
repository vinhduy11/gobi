import Testing
@testable import GobiModel

@Suite("Environments")
struct EnvironmentTests {
    private let toml = """
    [profiles.local]
    default = true
    env_files = [".env"]

    [profiles.local.vars]
    APP_ENV = "local"

    [profiles.staging]
    remote = true
    env_files = [".env.base", ".env.staging"]

    [profiles.staging.vars]
    APP_ENV = "staging"
    DB_HOST = "postgres.staging.example"
    GREETING = "say \\"hi\\"\\n"

    [profiles.staging.secrets]
    DB_PASSWORD = true

    [profiles.staging.go]
    toolchain = "1.25.10"
    tags = "staging"
    goflags = "-mod=readonly"
    goos = "darwin"
    goarch = "arm64"

    [profiles.staging.safety]
    confirm_non_local = false
    block_destructive = true
    """

    @Test func theFileIsReadIntoProfiles() throws {
        let file = try EnvironmentFile.parse(toml)
        #expect(file.profiles.map(\.name) == ["local", "staging"])
        let local = file.profiles[0], staging = file.profiles[1]
        #expect(local.isDefault && !local.isRemote && local.envFiles == [".env"] && local.vars == [EnvVar(name: "APP_ENV", value: "local")])
        #expect(staging.isRemote && staging.envFiles == [".env.base", ".env.staging"])
        #expect(staging.vars.map(\.name) == ["APP_ENV", "DB_HOST", "GREETING"] && staging.vars[2].value == "say \"hi\"\n")
        #expect(staging.secretNames == ["DB_PASSWORD"])
        #expect(staging.toolchain == "1.25.10" && staging.tags == "staging" && staging.goflags == "-mod=readonly" && staging.goos == "darwin" && staging.goarch == "arm64")
        #expect(!staging.confirmNonLocal && staging.blockDestructive)
        #expect(local.confirmNonLocal && local.blockDestructive)   // safe by default
    }

    @Test func writingAndReadingAgainKeepsEverything() throws {
        let file = try EnvironmentFile.parse(toml)
        #expect(try EnvironmentFile.parse(file.toml()) == file)
    }

    @Test func aMalformedFileIsRefusedWithALine() {
        #expect(throws: EnvironmentFile.ParseError.self) { try EnvironmentFile.parse("[profiles.x\nbad") }
        #expect(throws: EnvironmentFile.ParseError.self) { try EnvironmentFile.parse("[profiles.x]\nkey value") }
    }

    @Test func unknownTablesAndKeysAreIgnored() throws {
        let file = try EnvironmentFile.parse("[other]\nx = 1\n[profiles.a]\nfuture = true\n[profiles.a.vars]\nK = \"v\"\n")
        #expect(file.profiles.map(\.name) == ["a"] && file.profiles[0].vars.count == 1)
    }

    @Test func variablesOverrideFilesAndLaterFilesOverrideEarlierOnes() {
        var profile = EnvProfile(name: "p")
        profile.envFiles = [".env.base", ".env.staging"]
        profile.vars = [EnvVar(name: "C", value: "from-var")]
        profile.secretNames = ["S"]
        let resolved = EnvResolver.resolve(profile, files: [".env.base": "A=1\nB=base\nC=base\n", ".env.staging": "B=staging\n# comment\nexport D=\"quoted\"\n"], secrets: ["S": "secret"])
        #expect(resolved.value(of: "A") == "1" && resolved.value(of: "B") == "staging" && resolved.value(of: "C") == "from-var" && resolved.value(of: "D") == "quoted")
        #expect(resolved.source(of: "B") == ".env.staging" && resolved.source(of: "C") == "profile" && resolved.source(of: "S") == "Keychain")
        #expect(resolved.value(of: "S") == "secret")
    }

    @Test func goSettingsBecomeEnvironmentVariables() {
        var profile = EnvProfile(name: "p")
        profile.tags = "staging integration"
        profile.goflags = "-mod=readonly"
        profile.goos = "linux"
        profile.goarch = "amd64"
        let resolved = EnvResolver.resolve(profile, files: [:], secrets: [:])
        #expect(resolved.value(of: "GOFLAGS") == "-mod=readonly -tags=staging,integration")
        #expect(resolved.value(of: "GOOS") == "linux" && resolved.value(of: "GOARCH") == "amd64")
        #expect(EnvResolver.resolve(EnvProfile(name: "q"), files: [:], secrets: [:]).value(of: "GOFLAGS") == nil)
    }

    @Test func targetsAreFoundFromHostsAndUrlsAndFlaggedWhenNotLocal() {
        var profile = EnvProfile(name: "p")
        profile.envFiles = [".env.staging"]
        profile.vars = [EnvVar(name: "DB_HOST", value: "postgres.staging.example"), EnvVar(name: "DB_PORT", value: "5432"), EnvVar(name: "REDIS_URL", value: "redis://redis.staging.example:6379/0"), EnvVar(name: "MQTT_HOST", value: "localhost"), EnvVar(name: "MQTT_PORT", value: "1883"), EnvVar(name: "APP_ENV", value: "staging")]
        let targets = EnvTargets.find(in: EnvResolver.resolve(profile, files: [".env.staging": "KAFKA_BROKERS=kafka.staging.example:9092,kafka2.staging.example:9092\n"], secrets: [:]))
        #expect(targets.map(\.component) == ["Kafka", "MQTT", "PostgreSQL", "Redis"])
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.component, $0) })
        #expect(byName["PostgreSQL"]?.address == "postgres.staging.example:5432" && byName["PostgreSQL"]?.isLocal == false)
        #expect(byName["Redis"]?.address == "redis.staging.example:6379" && byName["Redis"]?.isLocal == false)
        #expect(byName["MQTT"]?.address == "localhost:1883" && byName["MQTT"]?.isLocal == true)
        #expect(byName["Kafka"]?.address == "kafka.staging.example:9092" && byName["Kafka"]?.source == ".env.staging")
        #expect(EnvTargets.nonLocal(targets).count == 3)
    }

    @Test func loopbackNamesAreLocal() {
        for host in ["localhost", "127.0.0.1", "::1", "0.0.0.0", "", "db.localhost"] { #expect(EnvTargets.isLocal(host: host), "\(host)") }
        for host in ["postgres.staging.example", "10.1.2.3", "redis"] { #expect(!EnvTargets.isLocal(host: host), "\(host)") }
    }

    @Test func variableNamesMustBeValidIdentifiers() {
        #expect(EnvVar.isValidName("DB_HOST") && EnvVar.isValidName("_x1"))
        #expect(!EnvVar.isValidName("") && !EnvVar.isValidName("1A") && !EnvVar.isValidName("A-B") && !EnvVar.isValidName("A B") && !EnvVar.isValidName("A=B"))
    }
}
