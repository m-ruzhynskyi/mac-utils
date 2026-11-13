# Модели

`IrisLandmarks.mlpackage` — MediaPipe Iris landmark (Google, Apache-2.0): 71 точка контура глаза и 5 точек радужки по кропу глаза 64×64.
Веса — из переноса на PyTorch [cedriclmenard/irislandmarks.pytorch](https://github.com/cedriclmenard/irislandmarks.pytorch) (Apache-2.0),
переведены в Core ML (mlprogram, fp16) через coremltools. Лицензия — `IrisLandmarks-LICENSE.txt`.
Модуль «Взгляд в камеру» (MUGaze) компилирует пакет при первом включении и кладёт результат в Application Support.
