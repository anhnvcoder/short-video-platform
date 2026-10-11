// Package migrations holds feed-service's goose SQL migrations, embedded into the binary so the
// `migrate` subcommand needs no files on disk.
package migrations

import "embed"

// FS holds the migration files, named <version>_<name>.sql, at its root.
//
//go:embed *.sql
var FS embed.FS
