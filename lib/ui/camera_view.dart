import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../tflite/classifier.dart';
import '../tflite/recognition.dart';
import '../tflite/stats.dart';
import 'camera_view_singleton.dart';
import '../utils/isolate_utils.dart';

/// [CameraView] sends each frame for inference
class CameraView extends StatefulWidget {
  /// Callback to pass results after inference to [HomeView]
  final Function(List<Recognition> recognitions) resultsCallback;

  /// Callback to inference stats to [HomeView]
  final Function(Stats stats) statsCallback;

  /// Constructor
  const CameraView(this.resultsCallback, this.statsCallback);
  @override
  _CameraViewState createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> with WidgetsBindingObserver {
  /// List of available cameras
  late List<CameraDescription> cameras;

  /// Controller
  late CameraController cameraController;

  /// true when inference is ongoing
  late bool predicting;

  /// Instance of [Classifier]
  late Classifier classifier;

  /// Instance of [IsolateUtils]
  late IsolateUtils rootIsolate;

  @override
  void initState() {
    super.initState();
    initStateAsync();
  }

  void initStateAsync() async {
    WidgetsBinding.instance.addObserver(this);

    // Spawn a new isolate
    rootIsolate = IsolateUtils();
    await rootIsolate.establishConn();

    // Camera initialization
    initializeCamera();

    // Create an instance of classifier to load model and labels
    classifier = Classifier();

    // Initially predicting = false
    predicting = false;
    print('initialized finished');
  }

  /// Initializes the camera by setting [cameraController]
  void initializeCamera() async {
    cameras = await availableCameras();

    // cameras[0] for rear-camera
    cameraController =
        CameraController(cameras[1], ResolutionPreset.high, enableAudio: false);

    cameraController.initialize().then((_) async {
      // Stream of image passed to [onLatestImageAvailable] callback
      print('recording');
      await cameraController.startImageStream(onLatestImageAvailable);

      /// previewSize is size of each image frame captured by controller
      ///
      /// 352x288 on iOS, 240p (320x240) on Android with ResolutionPreset.low
      Size? previewSize = cameraController.value.previewSize;

      /// previewSize is size of raw input image to the model
      CameraViewSingleton.inputImageSize = previewSize!;

      // the display width of image on screen is
      // same as screenWidth while maintaining the aspectRatio
      Size screenSize = MediaQuery.of(context).size;
      CameraViewSingleton.screenSize = screenSize;
      CameraViewSingleton.ratio = screenSize.width / previewSize.height;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Return empty container while the camera is not initialized
    if (!cameraController.value.isInitialized) {
      return const SizedBox.shrink();
    }

    // return AspectRatio(
    //     aspectRatio: cameraController.value.aspectRatio,
    //     child: CameraPreview(cameraController));
    return CameraPreview(cameraController);
  }

  /// Callback to receive each frame [CameraImage] perform inference on it
  onLatestImageAvailable(CameraImage cameraImage) async {
    if (predicting) {
      return;
    }

    setState(() {
      predicting = true;
    });

    var uiThreadTimeStart = DateTime.now().millisecondsSinceEpoch;
    print('start to assign address');
    // Data to be passed to inference isolate
    var isolateData = IsolateData(
        cameraImage, classifier.interpreter.address, classifier.labels);

    // We could have simply used the compute method as well however
    // it would be as in-efficient as we need to continuously passing data
    // to another isolate.
    print('start to inference');
    /// perform inference in separate isolate
    // Map<String, dynamic> inferenceResults = await inference(isolateData);
    //
    // var uiThreadInferenceElapsedTime =
    //     DateTime.now().millisecondsSinceEpoch - uiThreadTimeStart;
    //
    // // pass results to HomeView
    // widget.resultsCallback(inferenceResults["recognitions"]);
    //
    // // pass stats to HomeView
    // widget.statsCallback((inferenceResults["stats"] as Stats)
    //   ..totalElapsedTime = uiThreadInferenceElapsedTime);

    // set predicting to false to allow new frames
    setState(() {
      predicting = false;
    });
  }

  /// Runs inference in another isolate
  Future<Map<String, dynamic>> inference(IsolateData isolateData) async {
    // create an new isolate called inference
    ReceivePort rootIsolateReceivePort = ReceivePort();
    SendPort? newIsolateSendPort = rootIsolate.newIsolateSendPort;
    // bind data's responsePort with root receive port
    isolateData.responsePort = rootIsolateReceivePort.sendPort;
    // send data to new isolate
    newIsolateSendPort?.send(isolateData);
    // read results from inference isolate
    var results = await rootIsolateReceivePort.first;
    return results;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.paused:
        cameraController.stopImageStream();
        break;
      case AppLifecycleState.resumed:
        if (!cameraController.value.isStreamingImages) {
          await cameraController.startImageStream(onLatestImageAvailable);
        }
        break;
      default:
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    cameraController.dispose();
    rootIsolate.killIsolate();
    super.dispose();
  }
}
