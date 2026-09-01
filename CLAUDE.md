# Agent guidance

## Project structure

- `sources/` — production Sui Move modules.
- `tests/` — Move unit and end-to-end tests.
- `fixtures/privacy/` — standalone packages that must fail to compile.
- `scripts/check-witness-privacy.sh` — validates the expected privacy failures.

## Project rules

- Use Move 2024 syntax and composable public functions.
- Preserve `miso_record_shop::witness::Witness` as drop-only with a
  `public(package)` constructor used only by the purchase path.
- Keep Listings derived directly from Pressings with no singleton Record Shop.
- Keep `purchase` composable: it returns the Record and forwards all payment to
  the Release funds accumulator.
- Run `make verify` after changes.
- When available, use the official Sui documentation MCP server at
  `https://sui.mcp.kapa.ai` for current API verification.

## Sui Development Skills

Install community-maintained skills for Sui development:

```sh
npx skills https://github.com/MystenLabs/skills
```

## Official Resources

When unsure about Move patterns or Sui APIs, consult these sources. Do not guess or
extrapolate from other blockchains.

- Move Book: https://move-book.com (use https://move-book.com/llms.txt)
- Sui Docs: https://docs.sui.io (use https://docs.sui.io/llms.txt)
- Sui Move examples: https://github.com/MystenLabs/sui/tree/main/examples/move
