import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as imageLib;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../tflite/classifier.dart';
import 'image_utils.dart';

/// Manages separate Isolate instance for inference
class IsolateUtils {
  static const String debugName = "InferenceIsolate";

  late Isolate _newIsolate;
  final ReceivePort _rootIsolateReceivePort = ReceivePort();
  late SendPort _newIsolateSendPort;

  SendPort? get newIsolateSendPort => _newIsolateSendPort;

  Future<void> establishConn() async {
    SendPort rootIsolateSendPort = _rootIsolateReceivePort.sendPort;
    _newIsolate = await Isolate.spawn<SendPort>(
      createNewIsolateContext,
      rootIsolateSendPort,
      debugName: debugName,
    );

    _newIsolateSendPort = await _rootIsolateReceivePort.first;
  }

  static void createNewIsolateContext(SendPort rootIsolateSendPort) async {
    // sub receive port
    ReceivePort newIsolateReceivePort = ReceivePort();
    SendPort newIsolateSendPort = newIsolateReceivePort.sendPort;
    // send new isolate send port to root isolate
    rootIsolateSendPort.send(newIsolateSendPort);
    receiveMsgFromRootIsolate(newIsolateReceivePort);
  }

  static void receiveMsgFromRootIsolate(
      ReceivePort newIsolateReceivePort) async {
    await for (IsolateData isolateData in newIsolateReceivePort) {
      Classifier classifier = Classifier(
          givenInterpreter:
              Interpreter.fromAddress(isolateData.interpreterAddress!),
          labels: isolateData.labels);
      imageLib.Image? image =
          ImageUtils.convertCameraImage(isolateData.cameraImage!);
      if (Platform.isAndroid) {
        image = imageLib.copyRotate(image!, 90);
      }
      Map<String, dynamic>? results = classifier.predict(image!);
      // send results to inference isolate
      isolateData.responsePort?.send(results);
    }
    // print('${messageList[0] as String}');
    // final messageSendPort = messageList[1] as SendPort;
    // //第10步: 收到消息后，立即向rootIsolate 发送一个回复消息
    // print("11");
    // messageSendPort.send('this is reply from new isolate: hello root isolate!');
  }

  void killIsolate() {
    _newIsolate.kill();
  }
}

/// Bundles data to pass between Isolate
class IsolateData {
  CameraImage? cameraImage;
  int? interpreterAddress;
  List<String>? labels;
  SendPort? responsePort;

  IsolateData(
    this.cameraImage,
    this.interpreterAddress,
    this.labels,
  );
}
