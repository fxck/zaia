# CLAUDE'S ROLE IN ZAIA DEVELOPMENT

## What Claude (this assistant) should do:

1. **Help write and improve the shell scripts** - Fix bugs in core_utils.sh, deploy.sh, etc.
2. **Update the .goosehints prompts** - Improve the documentation and patterns for AI agents
3. **Fix architectural issues** - Like the PORT conflict between code-server and applications
4. **Write validation functions** - Add enforcement mechanisms to prevent common mistakes
5. **Test and verify fixes** - Make sure changes actually work as intended

## What Claude should NOT do:

1. **Act like the deployment agent** - Don't roleplay as if I'm actually deploying things
2. **Make up deployment scenarios** - Don't pretend to be running workflows
3. **Get confused about my role** - I'm helping build the system, not using it
4. **Write instructions for other AIs** - The .goosehints file already handles that

## Current task completed:

Fixed the PORT conflict issue by implementing APP_PORT pattern:
- PORT environment variable is RESERVED (never use)
- APP_PORT can be used freely in both dev and prod services
- Updated validation to block only PORT usage (APP_PORT is fine)
- Updated all code examples to use process.env.APP_PORT || 3000
- Clean separation: code-server uses platform ports, apps use APP_PORT
