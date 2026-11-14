# Модели

`IrisLandmarks.mlpackage` — MediaPipe Iris landmark (Google, Apache-2.0): 71 точка контура глаза и 5 точек радужки по кропу глаза 64×64.
Веса — из переноса на PyTorch [cedriclmenard/irislandmarks.pytorch](https://github.com/cedriclmenard/irislandmarks.pytorch) (Apache-2.0),
переведены в Core ML (mlprogram, fp16) через coremltools. Лицензия — `IrisLandmarks-LICENSE.txt`.
Модуль «Взгляд в камеру» (MUGaze) компилирует пакет при первом включении и кладёт результат в Application Support.

`FaceLandmarks.mlpackage` — MediaPipe Face Landmarker v2, модель `face_landmarks_detector` (Google, Apache-2.0): 478 точек лица
по кропу 256×256. Из неё берутся веки (на узких и широко раскрытых глазах, в том числе в очках, точнее контура Iris).
Переведена из `face_landmarker.task` (tflite) своим переводом граф → PyTorch (те же операции и веса, расхождение
с TFLite 0,0003 px) → Core ML (mlprogram, fp16); ~0,6 мс на ANE. Лицензия — `FaceLandmarks-LICENSE.txt`.
