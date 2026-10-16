// Кто вправе пользоваться ключом устройства и куда может уходить окно.
// Ключевой API — только у страницы ретранслятора в главном кадре главного окна; чужой сайт его не получает.

function originOf(url) {
  try {
    const origin = new URL(String(url)).origin;
    return origin === "null" ? null : origin;
  } catch (_) { return null; }
}

// frame — event.senderFrame; mainFrame — главный кадр окна приложения. Вложенные кадры и чужие адреса не проходят.
function isTrustedSender(frame, mainFrame, relayUrl) {
  if (!frame || !mainFrame) return false;
  // WebFrameMain может прийти другим объектом для того же кадра: тогда сверяем процесс и routingId, а у кадра не должно быть родителя.
  const sameFrame = frame === mainFrame
    || (!frame.parent && frame.processId === mainFrame.processId && frame.routingId === mainFrame.routingId
      && frame.processId !== undefined && frame.routingId !== undefined);
  if (!sameFrame) return false;
  const expected = originOf(relayUrl);
  return !!expected && originOf(frame.url) === expected;
}

// Переход окна: "allow" — страница ретранслятора или offline.html; "external" — http/https на чужой адрес (во внешний браузер);
// "deny" — всё остальное (file://, javascript:, data: и т. д.).
function navigationAction(url, relayUrl, offlineUrl) {
  const target = String(url);
  const relay = originOf(relayUrl);
  if (relay && originOf(target) === relay) return "allow";
  if (offlineUrl && target.split(/[?#]/)[0] === String(offlineUrl).split(/[?#]/)[0]) return "allow";
  return /^https?:\/\//i.test(target) ? "external" : "deny";
}

module.exports = { originOf, isTrustedSender, navigationAction };
