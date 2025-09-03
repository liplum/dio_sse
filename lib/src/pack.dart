class EventPack {
  final String id;
  final String event;
  final String data;

  const EventPack({required this.id, required this.event, required this.data});

  @override
  String toString() {
    return "#$id [$event]: $data";
  }

  Map<String, dynamic> toJson() => {'id': id, 'event': event, 'data': data};

  factory EventPack.fromJson(Map<String, dynamic> json) =>
      EventPack(id: json['id'] as String, event: json['event'] as String, data: json['data'] as String);

  @override
  bool operator ==(Object other) {
    if (other is! EventPack || other.runtimeType != runtimeType) return false;
    return id == other.id && event == other.event && data == other.data;
  }

  @override
  int get hashCode => Object.hash(id, event, data);
}
