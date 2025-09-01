import 'package:json_annotation/json_annotation.dart';

part 'pack.g.dart';

@JsonSerializable(explicitToJson: true)
class EventPack {
  final String id;
  final String event;
  final String data;

  const EventPack({required this.id, required this.event, required this.data});

  @override
  String toString() {
    return "$id $event $data";
  }

  Map<String, dynamic> toJson() => _$EventPackToJson(this);

  factory EventPack.fromJson(Map<String, dynamic> json) => _$EventPackFromJson(json);

  @override
  bool operator ==(Object other) {
    if (other is! EventPack || other.runtimeType != runtimeType) return false;
    return id == other.id && event == other.event && data == other.data;
  }

  @override
  int get hashCode => Object.hash(id, event, data);
}
