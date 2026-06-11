import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final program = await ui.FragmentProgram.fromAsset('shaders/fae_orb.frag');
  runApp(FaeOrbPocApp(program: program));
}

class FaeOrbPocApp extends StatelessWidget {
  const FaeOrbPocApp({required this.program, super.key});

  final ui.FragmentProgram program;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: FaeOrbPocPage(program: program),
    );
  }
}

class FaeOrbPocPage extends StatefulWidget {
  const FaeOrbPocPage({required this.program, super.key});

  final ui.FragmentProgram program;

  @override
  State<FaeOrbPocPage> createState() => _FaeOrbPocPageState();
}

class _FaeOrbPocPageState extends State<FaeOrbPocPage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  double _manualAudio = 0.25;
  double _quality = 1.0;
  bool _reduceMotion = false;
  bool _simulateVoice = true;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      // POC runs at display cadence; production should throttle by state:
      // idle ~1fps, listening ~10fps, thinking/speaking ~30fps, hidden paused.
      // Reduced motion freezes repaint work instead of merely freezing shader time.
      if (_reduceMotion) return;
      setState(() => _elapsed = elapsed);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double get _timeSeconds => _elapsed.inMicroseconds / Duration.microsecondsPerSecond;

  double get _audioLevel {
    if (!_simulateVoice) return _manualAudio;
    final t = _timeSeconds;
    final phrase = math.pow(0.5 + 0.5 * math.sin(t * 2.7), 2.0).toDouble();
    final tremor = 0.5 + 0.5 * math.sin(t * 19.0);
    return (0.10 + phrase * 0.55 + tremor * 0.08).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final audio = _audioLevel;
    return Scaffold(
      backgroundColor: const Color(0xFF090604),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            Text(
              'Fae Orb — Flutter Shader POC',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: const Color(0xFFFFD77A),
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Golden fog, Siri-like glass rim, procedural single-pass fragment shader',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
            ),
            Expanded(
              child: Center(
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: const Size.square(420),
                    painter: FaeOrbPainter(
                      program: widget.program,
                      time: _timeSeconds,
                      audio: audio,
                      quality: _quality,
                      reduceMotion: _reduceMotion,
                    ),
                  ),
                ),
              ),
            ),
            _Controls(
              audio: audio,
              manualAudio: _manualAudio,
              quality: _quality,
              reduceMotion: _reduceMotion,
              simulateVoice: _simulateVoice,
              onManualAudio: (value) => setState(() => _manualAudio = value),
              onQuality: (value) => setState(() => _quality = value),
              onReduceMotion: (value) => setState(() => _reduceMotion = value),
              onSimulateVoice: (value) => setState(() => _simulateVoice = value),
            ),
          ],
        ),
      ),
    );
  }
}

class FaeOrbPainter extends CustomPainter {
  FaeOrbPainter({
    required this.program,
    required this.time,
    required this.audio,
    required this.quality,
    required this.reduceMotion,
  });

  final ui.FragmentProgram program;
  final double time;
  final double audio;
  final double quality;
  final bool reduceMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();
    // Uniform order mirrors shaders/fae_orb.frag.
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, time)
      ..setFloat(3, audio)
      ..setFloat(4, quality)
      ..setFloat(5, reduceMotion ? 1.0 : 0.0);

    final paint = Paint()
      ..shader = shader
      ..isAntiAlias = true;

    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant FaeOrbPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.audio != audio ||
        oldDelegate.quality != quality ||
        oldDelegate.reduceMotion != reduceMotion;
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.audio,
    required this.manualAudio,
    required this.quality,
    required this.reduceMotion,
    required this.simulateVoice,
    required this.onManualAudio,
    required this.onQuality,
    required this.onReduceMotion,
    required this.onSimulateVoice,
  });

  final double audio;
  final double manualAudio;
  final double quality;
  final bool reduceMotion;
  final bool simulateVoice;
  final ValueChanged<double> onManualAudio;
  final ValueChanged<double> onQuality;
  final ValueChanged<bool> onReduceMotion;
  final ValueChanged<bool> onSimulateVoice;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            border: Border.all(color: const Color(0x44FFD77A)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SliderRow(
                  label: 'Audio energy',
                  value: simulateVoice ? audio : manualAudio,
                  onChanged: simulateVoice ? null : onManualAudio,
                ),
                _SliderRow(
                  label: 'Quality tier',
                  value: quality,
                  onChanged: onQuality,
                ),
                Row(
                  children: [
                    Expanded(
                      child: SwitchListTile.adaptive(
                        title: const Text('Simulate voice'),
                        value: simulateVoice,
                        onChanged: onSimulateVoice,
                      ),
                    ),
                    Expanded(
                      child: SwitchListTile.adaptive(
                        title: const Text('Reduce motion'),
                        value: reduceMotion,
                        onChanged: onReduceMotion,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(value.toStringAsFixed(2), textAlign: TextAlign.end),
        ),
      ],
    );
  }
}
