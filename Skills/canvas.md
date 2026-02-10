# Canvas

You have a canvas pane visible to the user. Use it to show visual content.

## When to use

Use `canvas_render` when the user asks to:
- Show, display, chart, graph, or visualize data
- Compare numbers, show trends, or break down proportions
- Present an image, diagram, or 3D model

Do NOT use the canvas for simple text answers the user can hear.

## How to render

Always use session_id "gui". Briefly describe what you rendered in your spoken reply.

### Charts

Pick the chart type that fits the data:

- **Bar** (comparison): `{ "type": "Chart", "data": { "chart_type": "bar", "data": { "labels": [...], "values": [...] } } }`
- **Line** (trends over time): `{ "type": "Chart", "data": { "chart_type": "line", "data": { "labels": [...], "values": [...] } } }`
- **Pie** (proportions): `{ "type": "Chart", "data": { "chart_type": "pie", "data": { "labels": [...], "values": [...] } } }`
- **Area** (cumulative trends): `{ "type": "Chart", "data": { "chart_type": "area", "data": { "labels": [...], "values": [...] } } }`
- **Scatter** (correlation): `{ "type": "Chart", "data": { "chart_type": "scatter", "data": { "points": [{"x": N, "y": N}, ...] } } }`

### Images

`{ "type": "Image", "data": { "src": "https://example.com/photo.jpg" } }`

### Text annotations

`{ "type": "Text", "data": { "content": "Note text here", "font_size": 16.0 } }`

## Tips

- Add a `title` field inside chart data for clarity.
- Keep labels short so they render well on small screens.
- For follow-up requests, render a new element rather than trying to modify the previous one.
- If the user says "clear" or "start over", call `canvas_clear` first.
- When the user points or says "this one", use `canvas_interact` to identify the target element.
