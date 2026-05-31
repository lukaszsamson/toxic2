# `:imported` tests exercise the large imported backlog corpora and are excluded by default (they
# are a report-only ratchet, not part of the curated gate). Run them with:
#   mix test --include imported
ExUnit.configure(exclude: [:imported])
ExUnit.start()
