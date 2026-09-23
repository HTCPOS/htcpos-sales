// نفس إعدادات Firebase الموجودة بالظبط في index.html - لازم تتطابق عشان الإشعارات تشتغل صح
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: "AIzaSyBVvW-gB2p0MR85iXgyE35flEfbusrgn0Y",
  authDomain: "htcpos-6f17b.firebaseapp.com",
  databaseURL: "https://htcpos-6f17b-default-rtdb.europe-west1.firebasedatabase.app",
  projectId: "htcpos-6f17b",
  storageBucket: "htcpos-6f17b.firebasestorage.app",
  messagingSenderId: "243875710442",
  appId: "1:243875710442:web:f1375cb5ccc86bdbf79e93"
});

const messaging = firebase.messaging();

// بتتنفذ لما إشعار يوصل والموقع (PWA) مقفول أو في الخلفية - هنا بالظبط الجزء اللي كان ناقص
messaging.onBackgroundMessage((payload) => {
  const title = (payload.notification && payload.notification.title) || 'إشعار من منظومة المبيعات';
  const options = {
    body: (payload.notification && payload.notification.body) || '',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    dir: 'rtl',
    lang: 'ar'
  };
  self.registration.showNotification(title, options);
});

// لما المستخدم يدوس على الإشعار، نفتحله الموقع (لو مفتوح أصلاً نركّز عليه بدل ما نفتح نسخة جديدة)
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
      for (const client of windowClients) {
        if ('focus' in client) return client.focus();
      }
      if (clients.openWindow) return clients.openWindow('./');
    })
  );
});
