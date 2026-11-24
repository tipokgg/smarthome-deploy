// Датчик температуры и влажности HOBEIAN ZG-227Z (санузел 2 этажа, 24.11.2026). Встроенное описание zigbee2mqtt 2.14.3
// узнаёт модель ZG-227Z по modelID и ждёт протокол Tuya (кластер 0xEF00, датапоинты 1 - температура, 2 - влажность).
// У этого экземпляра (manufacturerName HOBEIAN, прошивка 0122052017) кластера Tuya нет, есть стандартные
// msTemperatureMeasurement (1026) и msRelativeHumidity (1029): температура в zigbee2mqtt не появлялась вовсе.
// Описание отсюда главнее встроенного; отпечаток - по производителю, чтобы TS0601-варианты под той же моделью
// остались на встроенном.
// Отчёты: по умолчанию температура уходит только при изменении на 1°, а умному климату нужна точность десятых -
// изменение на 0,1° (не чаще раза в минуту) и не реже раза в 30 мин, как у TS0201 в соседних комнатах.
// version: zigbee2mqtt перенастраивает устройство, когда она меняется (при 0.0.0 - никогда); поменял отчёты -
// подними версию, и каждый датчик перенастроится, как только проснётся.
import * as m from "zigbee-herdsman-converters/lib/modernExtend";

export default {
  zigbeeModel: ["ZG-227Z"],
  fingerprint: [{modelID: "ZG-227Z", manufacturerName: "HOBEIAN"}],
  model: "ZG-227Z-ZCL",
  vendor: "HOBEIAN",
  description: "Temperature & humidity sensor (standard ZCL clusters)",
  version: "1.0.0",
  extend: [
    m.temperature({reporting: {min: "1_MINUTE", max: "30_MINUTES", change: 10}}),
    m.humidity({reporting: {min: "1_MINUTE", max: "1_HOUR", change: 100}}),
    m.battery(),
  ],
};
