# Ambient Agent

A native macOS app that analyzes your digital life to surface insights about your relationships, communication patterns, and wellbeing.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5-green)

## Features

### Insights Dashboard
- **Wellbeing Score** - Composite score based on sleep patterns, social connection, and stress indicators
- **Communication Patterns** - Hourly and daily activity visualization
- **Relationship Tiers** - Automatic categorization of contacts by engagement level

### People
- **Contact Analysis** - See message counts, reaction patterns, and relationship strength
- **Rich Metadata** - Sent/received ratios, heart reactions, media sharing stats
- **Privacy Controls** - Right-click to block contacts from all analytics

### Activity
- **Time Patterns** - When you're most active
- **Peak Hours** - Your busiest communication times
- **Volume Trends** - Daily message volume over the past 2 weeks

### Network Graph
- **Top Connections** - Your most engaged relationships
- **Group Chats** - Activity across group conversations
- **Relationship Strength** - Visual indicators of connection depth

### Privacy Features
- **Contact Blocking** - Completely hide specific contacts from all insights
- **Privacy Blur Mode** - Obscure names/numbers for screenshots
- **Local Processing** - All data stays on your Mac

## Requirements

- macOS 14.0 (Sonoma) or later
- Full Disk Access permission (for Messages database)
- Optional: Anthropic API key for AI-powered features

## Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/haasonsaas/ambient-agent.git
   cd ambient-agent
   ```

2. Open in Xcode:
   ```bash
   open AmbientAgent.xcodeproj
   ```

3. Build and run (⌘R)

4. Grant **Full Disk Access** when prompted:
   - System Settings → Privacy & Security → Full Disk Access
   - Enable for Ambient Agent

## Data Sources

| Source | Status | Access Method |
|--------|--------|---------------|
| iMessage | ✅ Active | SQLite (chat.db) |
| Calendar | ✅ Active | EventKit |
| Apple Mail | 🔜 Planned | ScriptingBridge |
| Safari | 🔜 Planned | SQLite + ScriptingBridge |
| Notes | 🔜 Planned | AppleScript |

## Architecture

```
AmbientAgent/
├── App/
│   ├── AmbientAgentApp.swift    # Main app entry
│   └── AppState.swift           # Observable app state
├── Views/
│   ├── Dashboard/               # Main views (Insights, People, Activity, Graph)
│   ├── MenuBar/                 # Menu bar popover
│   └── Settings/                # Preferences with Privacy tab
├── Services/
│   └── InsightsService.swift    # Core data loading & analysis
└── AmbientCore/                 # Shared models & utilities
```

## Privacy

Ambient Agent is designed with privacy as a core principle:

- **100% Local** - All data processing happens on your Mac
- **No Telemetry** - No data is sent anywhere without your explicit action
- **Blocking** - Permanently hide any contact from analytics
- **Blur Mode** - Share screenshots without exposing contact info
- **Open Source** - Audit the code yourself

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

Built with:
- SwiftUI & SwiftData
- SQLite3 for Messages database access
- Claude API for AI features (optional)
