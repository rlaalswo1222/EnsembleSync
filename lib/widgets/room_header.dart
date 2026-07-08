import 'package:flutter/material.dart';

class RoomHeader extends StatelessWidget {
  static const _primary = Color(0xFF0F766E);
  static const _avatarColors = [
    Color(0xFF0F766E),
    Color(0xFFEC4899),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFF3B82F6),
  ];

  final String roomCode;
  final List<String> participantNames;
  final VoidCallback onShareRoom;

  const RoomHeader({
    super.key,
    required this.roomCode,
    required this.participantNames,
    required this.onShareRoom,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('방 코드',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDFA),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  roomCode,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _primary,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: '방 코드 공유',
                child: GestureDetector(
                  onTap: onShareRoom,
                  child: const Icon(Icons.share_rounded,
                      size: 16, color: Color(0xFF9CA3AF)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('참가자 ${participantNames.length}명',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(width: 8),
              ...participantNames.asMap().entries.map((entry) {
                final color = _avatarColors[entry.key % _avatarColors.length];
                final initial =
                    entry.value.isNotEmpty ? entry.value.substring(0, 1) : '?';
                return Container(
                  margin: const EdgeInsets.only(right: 4),
                  width: 28,
                  height: 28,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }
}
