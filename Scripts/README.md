# Scripts

Integration test scripts for the three-agent message extraction pipeline.

## Prerequisites

Set your Gemini API key:
```bash
export GEMINI_API_KEY="your-api-key-here"
```

## Scripts

### test_agents.swift

Tests the three-agent pipeline with sample conversation data.

```bash
swift Scripts/test_agents.swift
```

### test_real_messages.swift

Tests the pipeline with real iMessage-format data from October 2025.

```bash
swift Scripts/test_real_messages.swift
```

## Pipeline Overview

The three-agent pipeline processes messages in stages:

1. **Story Agent**: Batches daily messages into a narrative summary
2. **Extractor Agent**: Extracts structured events/tasks from the narrative
3. **Formatter Agent**: Resolves dates to ISO 8601 and formats for calendar API

## Example Output

```
📖 STORY:
The user discussed meeting Sarah for coffee tomorrow at 2pm at Blue Bottle.
They also received a reminder about Dad's birthday dinner on Saturday...

🔍 EXTRACTED:
[{"title": "Coffee with Sarah", "type": "event", "rough_date": "tomorrow", ...}]

📅 FORMATTED:
{"events": [{"title": "Coffee with Sarah", "start_date": "2025-01-02T14:00:00-08:00", ...}]}
```
