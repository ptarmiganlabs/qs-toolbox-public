# qs-toolbox-public

A collection of scripts and tools for Qlik Sense administrators and developers, covering common operational tasks such as repository database analysis, user directory inspection, and environment health checks.

All tools are read-only unless explicitly stated otherwise. They are designed for **client-managed Qlik Sense** environments (i.e. on-premises deployments, not Qlik Cloud).

## ❤️ Support the project

If you find this project helpful and use it in your Qlik Sense environment, please consider supporting it financially! Your sponsorship helps ensure the project's long-term sustainability and allows me to continue maintaining it, fixing bugs, and adding new features.

**👉 [Sponsor the project on GitHub](https://github.com/sponsors/ptarmiganlabs)** - Click the "Sponsor" button at the repository page to become a sponsor.

* ⭐ **Star the repository** on GitHub - it helps others discover the project
* 🍴 **Fork and contribute** - pull requests are welcome!
* 💬 **Share your feedback** - let me know how you're using it
* 🐛 **Report issues** - help improve stability and functionality

*This project is maintained by [Göran Sander](https://github.com/mountaindude) and supported by [Ptarmigan Labs](https://ptarmiganlabs.com).*

---

## Repository layout

```text
qs-toolbox-public/
└── client-managed/
    └── powershell/
        └── repo-db-optimize/   ← Repository database analysis scripts
```

New tool sets are added as sibling folders under `client-managed/powershell/` (or other language subfolders as needed), each with their own `README.md`.

---

## Tools

### `client-managed/powershell/repo-db-optimize` — Repository database analysis

PowerShell scripts for read-only analysis of the Qlik Sense repository PostgreSQL database. Useful for understanding database health, table sizes, user counts, and group membership patterns.

| Script | Description |
| --- | --- |
| `repo-db-overview.ps1` | Comprehensive database overview: table sizes, row counts, indexes, user permissions |
| `user-group-memberships.ps1` | User group membership analysis: statistics, histograms, rankings, and bloat detection |

**Requirements:** PowerShell Core 6.0+, `psql` 12+, network access to the PostgreSQL host.

📁 See [client-managed/powershell/repo-db-optimize/README.md](client-managed/powershell/repo-db-optimize/README.md) for setup instructions, environment variables, and usage examples.

---

## General notes

- Scripts use environment variables for all configuration (host, port, credentials). No credentials are hardcoded.
- All database scripts connect via the `psql` CLI and are read-only unless the script explicitly states otherwise.
- Each tool folder contains a `docs/` subfolder with per-script documentation.

## License & Additional Resources

MIT, see [LICENSE](LICENSE) for details.

More Qlik Sense resources, tools & blog posts at [https://ptarmiganlabs.com](https://ptarmiganlabs.com)
