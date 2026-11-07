# Import the AIRDROP PUBGM source

The repository is prepared to import the complete website source archive without using Vercel yet.

## One-time source upload

1. Download the prepared source ZIP from the ChatGPT conversation.
2. Open the repository on GitHub.
3. Choose **Add file → Upload files**.
4. Create/use the folder named `imports` and upload the ZIP with this exact filename:
   `AIRDROP-PUBGM-source.zip`
5. Commit the upload to the `main` branch.

A GitHub Actions workflow watches for that exact archive path, validates the archive, extracts the contents of its `airdrop-pubgm/` folder into the repository root, and commits the application files. It then removes the uploaded ZIP from the repository.

## Important

- This process only prepares the GitHub repository. It does not create or connect a Vercel project.
- Keep the existing CODM repository and Supabase project separate.
- Do not upload any real `.env` file, API secret, service-role key, or password. The source archive contains only an `.env.example` template.
- The new Supabase project still needs its own complete initial schema and RPC functions before backend features can work.
