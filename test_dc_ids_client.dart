
import 'dart:convert';
import 'dart:typed_data';
// import 'package:pointycastle/export.dart'; // Commented out to run without pub get

// --- Simulation of Client logic ---

Uint8List _pad8(String s) {
  final src = utf8.encode(s);
  final out = Uint8List(8);
  final n = src.length > 8 ? 8 : src.length;
  out.setRange(0, n, src);
  return out;
}

String _normalizeLabelForDcid(String name, String defaultTask) {
  name = name.trim().toLowerCase();
  if (name.startsWith('results:')) {
    final i = name.indexOf(':');
    final task = (i >= 0 && i + 1 < name.length) ? name.substring(i + 1) : '';
    return (task.isEmpty ? defaultTask : task).toLowerCase();
  }
  if (name == 'results') return defaultTask.toLowerCase();
  return name;
}

int _dcIdFromTask(
  String name, {
  required int mod,
  Set<int> reserved = const {},
  String defaultTask = 'pose',
}) {
  if (mod < 2) mod = 2;

  final normalized = _normalizeLabelForDcid(name, defaultTask);


  // Simulate hash base values (verified via logs/Python in previous steps)
  // 'face' -> hash 0
  // 'pose' -> hash 12
  // 'face_recog' -> hash 2 (matches Python 'person' param)
  
  int base = 0;
  if (normalized == 'face') base = 0; 
  else if (normalized == 'pose') base = 12; 
  else if (normalized == 'face_recog') base = 2; 
  else {
      print("UNKNOWN TASK '$normalized' - cannot simulate hash");
      return -1;
  }
  
  // Simulation of: var dcid = (base % mod) & 0xFFFE;
  var dcid = (base % mod) & 0xFFFE;

  // walk by +2 while colliding with reserved
  while (reserved.contains(dcid)) {
    dcid = (dcid + 2) % mod;
    dcid &= 0xFFFE;
  }
  return dcid;
}

void main() {
    print("--- Client Simulation ---");
    final int sctpStreamMod = 16;
    final int ctrlDcId = 1; // Client default
    
    Set<int> assignedDcIds = {};
    // client adds ctrlDcId to reserved in _createLossyDC
    
    // Simulate creation order
    // Client logs showed face, then face_recog (Step 46 had face first?)
    // Actually logs (Step 46):
    // createLossyDC[face] -> id=0
    // createLossyDC[face_recog] -> id=2
    // then presumably pose?
    
    // Let's test "face"
    var reserved = <int>{ctrlDcId, ...assignedDcIds};
    var idFace = _dcIdFromTask('results:face', mod: sctpStreamMod, reserved: reserved);
    assignedDcIds.add(idFace);
    print("Client 'results:face' -> $idFace");
    
    // Let's test "face_recog"
    reserved = <int>{ctrlDcId, ...assignedDcIds};
    var idFaceRecog = _dcIdFromTask('results:face_recog', mod: sctpStreamMod, reserved: reserved);
    assignedDcIds.add(idFaceRecog);
    print("Client 'results:face_recog' -> $idFaceRecog");
    
    // Let's test "pose"
    reserved = <int>{ctrlDcId, ...assignedDcIds};
    var idPose = _dcIdFromTask('results:pose', mod: sctpStreamMod, reserved: reserved);
    assignedDcIds.add(idPose);
    print("Client 'results:pose' -> $idPose");
}
