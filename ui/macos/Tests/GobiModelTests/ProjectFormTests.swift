import Testing
@testable import GobiModel

@Suite("Project forms")
struct ProjectFormTests {
    @Test func aGoodNameHasNoProblem() {
        #expect(ProjectForm.problem(withName: "my-app.v2") == nil)
    }

    @Test(arguments: ["", "a/b", "..", ".hidden", "-rf", "my app", "a\\b"])
    func aBadNameHasAProblem(name: String) {
        #expect(ProjectForm.problem(withName: name) != nil)
    }

    @Test func aLongNameHasAProblem() {
        #expect(ProjectForm.problem(withName: String(repeating: "a", count: 101)) != nil)
    }

    @Test func aModulePathMayBeEmptyButNotHaveSpaces() {
        #expect(ProjectForm.problem(withModulePath: "") == nil)
        #expect(ProjectForm.problem(withModulePath: "example.com/acme/widget") == nil)
        #expect(ProjectForm.problem(withModulePath: "has space") != nil)
        #expect(ProjectForm.problem(withModulePath: "-flag") != nil)
    }

    @Test func repositoryNameComesFromTheLastPathPart() {
        #expect(ProjectForm.repositoryName(fromURL: "https://github.com/acme/widget.git") == "widget")
        #expect(ProjectForm.repositoryName(fromURL: "https://github.com/acme/widget") == "widget")
        #expect(ProjectForm.repositoryName(fromURL: "https://github.com/acme/widget/") == "widget")
        #expect(ProjectForm.repositoryName(fromURL: "git@github.com:acme/widget.git") == "widget")
        #expect(ProjectForm.repositoryName(fromURL: "ssh://git@host/team/svc.git") == "svc")
        #expect(ProjectForm.repositoryName(fromURL: "") == "")
    }

    @Test func cloneURLNeedsAKnownScheme() {
        #expect(ProjectForm.problem(withCloneURL: "https://github.com/acme/widget.git") == nil)
        #expect(ProjectForm.problem(withCloneURL: "git@github.com:acme/widget.git") == nil)
        #expect(ProjectForm.problem(withCloneURL: "") != nil)
        #expect(ProjectForm.problem(withCloneURL: "/local/path") != nil)
        #expect(ProjectForm.problem(withCloneURL: "ext::sh -c id") != nil)
        #expect(ProjectForm.problem(withCloneURL: "-oProxyCommand=x") != nil)
    }
}
