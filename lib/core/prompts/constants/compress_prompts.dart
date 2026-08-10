/// Compress context prompt presets (Issue #143).
const String defaultCompressPrompt =
    '''Provide a detailed summary of the following conversation for continuing in a new session.

The new session will not have access to the original conversation history, so preserve all context needed to continue seamlessly.

Focus on:
- Key topics discussed and why they matter
- Important decisions made and their reasoning
- Current work in progress and its state
- Next steps or open questions to address
- Any relevant technical details, code snippets, or configurations mentioned

Requirements:
1. Write in {locale} language, matching the original conversation language
2. Be concise but complete — do not omit important context
3. Output the summary directly without prefaces or meta-commentary
4. Start with a clear indicator (e.g., "[Summary of previous conversation]" or equivalent)

<conversation>
{content}
</conversation>''';

/// Detailed variant: drops the "concise" constraint and states an explicit
/// length band (20%-30% of the original) to encourage a thorough summary.
const String detailedCompressPrompt =
    '''Provide a detailed summary of the following conversation for continuing in a new session.

The new session will not have access to the original conversation history, so preserve all context needed to continue seamlessly.

Focus on:
- Key topics discussed and why they matter
- Important decisions made and their reasoning
- Current work in progress and its state
- Next steps or open questions to address
- Any relevant technical details, code snippets, or configurations mentioned

Requirements:
1. Write in {locale} language, matching the original conversation language
2. Be complete — do not omit important context. The compressed version can be 20%-30% of the original conversation in length.
3. Output the summary directly without prefaces or meta-commentary
4. Start with a clear indicator (e.g. "[Summary of previous conversation]" or equivalent)

<conversation>
{content}
</conversation>''';
