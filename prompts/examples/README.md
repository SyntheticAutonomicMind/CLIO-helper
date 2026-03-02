# Prompt Template Examples

This directory contains example prompt templates for different use cases.

## Available Templates

| Template | Description | Best For |
|----------|-------------|----------|
| `analyzer-strict.md` | Minimal responses, high signal-to-noise | Busy projects, technical-only support |
| `analyzer-friendly.md` | Warm, welcoming, broad scope | Community building, new projects |
| `analyzer-technical.md` | Detailed technical responses | Developer-focused projects |
| `analyzer-template.md` | Blank template with placeholders | Starting your own customization |

## How to Use

### 1. Copy the template you want:
```bash
cp prompts/examples/analyzer-friendly.md ~/.clio/prompts/analyzer-default.md
```

### 2. Configure prompts_dir in your config:
```json
{
    "prompts_dir": "~/.clio/prompts"
}
```

### 3. Customize as needed:
```bash
$EDITOR ~/.clio/prompts/analyzer-default.md
```

### 4. Test with dry-run:
```bash
clio-helper --once --dry-run --debug
```

## Template Comparison

### Strict Mode
- **Scope:** Narrow (bugs and errors only)
- **Response rate:** Low (skips most questions)
- **Tone:** Professional, concise
- **Use case:** Mature projects with high volume

### Friendly Mode
- **Scope:** Broad (most topics welcome)
- **Response rate:** High (responds to almost everything)
- **Tone:** Warm, encouraging, uses emoji
- **Use case:** Growing communities, onboarding users

### Technical Mode
- **Scope:** Medium (technical questions only)
- **Response rate:** Medium
- **Tone:** Detailed, includes code examples
- **Use case:** Developer-focused projects

## Customization Tips

### Changing Scope
Edit the "Scope" section to add/remove topics your bot handles.

### Changing Tone
Edit the "Response Guidelines" section to adjust how CLIO speaks.

### Adding Security Rules
Add project-specific security rules in the "Security Rules" section.

### Custom Output
Keep the JSON output format unchanged - CLIO expects this exact structure.

## Important

The `analyzer-default.md` file in the parent directory is the production prompt.
These examples are for reference and copying.
