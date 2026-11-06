package project

// CatalogueEntry describes one template of the New Project dialog. The ID is stable and is what project/new takes; the
// position in Catalogue is the dialog order. An entry that is not Available is shown but cannot be created yet.
type CatalogueEntry struct {
	ID        string
	Group     string
	Title     string
	Summary   string
	Available bool
}

// Catalogue returns the templates in dialog order.
func Catalogue() []CatalogueEntry {
	return []CatalogueEntry{
		{TemplateCLI, "Go module", "Command-line tool", "A main package with a test, ready to run.", true},
		{TemplateLibrary, "Go module", "Library", "A package other modules can import, with a test.", true},
		{TemplateHTTP, "Service", "HTTP service", "A net/http server with a /healthz route and a test.", true},
		{"grpc", "Service", "gRPC service", "A gRPC server with a health check. Not available yet: it needs generated code and downloaded modules.", false},
		{TemplateConsumer, "Service", "Message consumer", "A worker that reads from a source in a loop, stops cleanly on Ctrl-C and has a handler you can test.", true},
		{TemplateJob, "Service", "Scheduled job", "A job that runs once or on a timer, stops on Ctrl-C and exits with an error code when it fails.", true},
		{TemplateWorkspace, "Workspace", "go.work (multi-module)", "A go.work file with one module, ready for more.", true},
		{TemplateEmpty, "Other", "Empty module", "Only go.mod, for starting from nothing.", true},
		{"custom", "Other", "Custom templates…", "Templates from your own folder. Not available yet.", false},
	}
}
