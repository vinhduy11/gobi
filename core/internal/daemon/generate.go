package daemon

import (
	"gobi/core/internal/generate"
	"gobi/core/internal/wire"
)

// generateControl answers the Generate messages. The request carries the buffer version and every answer echoes it, so the
// UI drops a reply for a buffer that has changed since.
func generateControl(method string, fields []wire.Field) ([]byte, error) {
	req, err := generate.DecodeRequest(fields)
	if err != nil {
		return nil, err
	}
	switch method {
	case "generate/list":
		items, err := generate.List(req.Context)
		if err != nil {
			return nil, err
		}
		return generate.EncodeList(req.Version, items), nil
	case "generate/preview":
		result, err := generate.Preview(req)
		if err != nil {
			return nil, err
		}
		return generate.EncodeResult(result), nil
	default:
		result, err := generate.Render(req)
		if err != nil {
			return nil, err
		}
		return generate.EncodeResult(result), nil
	}
}
