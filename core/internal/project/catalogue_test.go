package project

import "testing"

func TestCatalogueListsEveryTemplateOnce(t *testing.T) {
	seen := map[string]bool{}
	for _, entry := range Catalogue() {
		if entry.ID == "" || entry.Group == "" || entry.Title == "" || entry.Summary == "" {
			t.Errorf("incomplete entry %+v", entry)
		}
		if seen[entry.ID] {
			t.Errorf("duplicate id %q", entry.ID)
		}
		seen[entry.ID] = true
		_, known := templates[entry.ID]
		if entry.Available != (known || entry.ID == TemplateWorkspace) {
			t.Errorf("%q: available = %v but Render knows it = %v", entry.ID, entry.Available, known)
		}
	}
	for _, id := range []string{TemplateCLI, TemplateLibrary, TemplateHTTP, TemplateConsumer, TemplateJob, TemplateWorkspace, TemplateEmpty, "grpc"} {
		if !seen[id] {
			t.Errorf("catalogue misses %q", id)
		}
	}
}
