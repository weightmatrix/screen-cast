"""Generate native and browser UI translations; no external translation service."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ['zh-Hant', 'en', 'es', 'de', 'fr', 'it', 'ja', 'ko']
# Source | Traditional Chinese | English | Spanish | German | French | Italian | Japanese | Korean
ROWS = '''
投屏|投屏|Cast|Transmitir|Übertragen|Diffuser|Trasmetti|送信|전송
接收|接收|Receive|Recibir|Empfangen|Recevoir|Ricevi|受信|수신
连接|連線|Connect|Conectar|Verbinden|Connecter|Connetti|接続|연결
断开|中斷連線|Disconnect|Desconectar|Trennen|Déconnecter|Disconnetti|切断|연결 해제
停止|停止|Stop|Detener|Stoppen|Arrêter|Interrompi|停止|중지
取消|取消|Cancel|Cancelar|Abbrechen|Annuler|Annulla|キャンセル|취소
接受|接受|Accept|Aceptar|Annehmen|Accepter|Accetta|許可|허용
拒绝|拒絕|Decline|Rechazar|Ablehnen|Refuser|Rifiuta|拒否|거절
复制|複製|Copy|Copiar|Kopieren|Copier|Copia|コピー|복사
刷新|重新整理|Refresh|Actualizar|Aktualisieren|Actualiser|Aggiorna|更新|새로 고침
选择|選擇|Select|Seleccionar|Auswählen|Sélectionner|Seleziona|選択|선택
匹配码|配對碼|Pairing code|Código de emparejamiento|Kopplungscode|Code d’association|Codice di abbinamento|ペアリングコード|페어링 코드
6–36 位数字|6–36 位數字|6–36 digits|6–36 dígitos|6–36 Ziffern|6 à 36 chiffres|6–36 cifre|6～36桁の数字|숫자 6~36자리
端口|連接埠|Port|Puerto|Port|Port|Porta|ポート|포트
公网接入申请|公網接入申請|Internet access request|Solicitud de acceso por Internet|Internetanfrage|Demande d’accès Internet|Richiesta di accesso Internet|インターネット接続申請|인터넷 접속 요청
暂无已连接设备|暫無已連線裝置|No connected devices|No hay dispositivos conectados|Keine verbundenen Geräte|Aucun appareil connecté|Nessun dispositivo connesso|接続中のデバイスなし|연결된 기기 없음
连接设备|連線裝置|Connected devices|Dispositivos conectados|Verbundene Geräte|Appareils connectés|Dispositivi connessi|接続デバイス|연결된 기기
网络详情|網路詳情|Network details|Detalles de red|Netzwerkdetails|Détails réseau|Dettagli di rete|ネットワーク詳細|네트워크 정보
网络往返 RTT|網路往返 RTT|Network round-trip time|Tiempo de ida y vuelta|Netzwerk-Roundtrip|Aller-retour réseau|Tempo di andata e ritorno|ネットワーク往復時間|네트워크 왕복 시간
诊断|診斷|Diagnostics|Diagnóstico|Diagnose|Diagnostic|Diagnostica|診断|진단
连接诊断|連線診斷|Connection diagnostics|Diagnóstico de conexión|Verbindungsdiagnose|Diagnostic de connexion|Diagnostica connessione|接続診断|연결 진단
本路投屏诊断|本路投屏診斷|Stream diagnostics|Diagnóstico de transmisión|Stream-Diagnose|Diagnostic de diffusion|Diagnostica trasmissione|この配信の診断|이 전송 진단
隐私政策|隱私權政策|Privacy policy|Política de privacidad|Datenschutzerklärung|Politique de confidentialité|Informativa sulla privacy|プライバシーポリシー|개인정보 처리방침
技术支持|技術支援|Support|Soporte|Support|Assistance|Assistenza|サポート|지원
接收工作台|接收工作臺|Receiver|Recepción|Empfang|Réception|Ricezione|受信画面|수신 화면
投屏工作台|投屏工作臺|Casting workspace|Panel de transmisión|Übertragungsbereich|Espace de diffusion|Area di trasmissione|送信画面|전송 화면
投屏模式|投屏模式|Cast mode|Modo de transmisión|Sendemodus|Mode diffusion|Modalità trasmissione|送信モード|전송 모드
切换到投屏|切換至投屏|Switch to casting|Cambiar a transmisión|Zum Senden wechseln|Passer à la diffusion|Passa alla trasmissione|送信に切り替え|전송으로 전환
关闭设置|關閉設定|Close settings|Cerrar ajustes|Einstellungen schließen|Fermer les réglages|Chiudi impostazioni|設定を閉じる|설정 닫기
接收页面声音|接收頁面聲音|Receive device audio|Recibir audio del dispositivo|Geräteton empfangen|Recevoir le son de l’appareil|Ricevi audio del dispositivo|デバイス音声を受信|기기 오디오 수신
接收话筒声音|接收麥克風聲音|Receive microphone audio|Recibir micrófono|Mikrofonton empfangen|Recevoir le microphone|Ricevi microfono|マイク音声を受信|마이크 오디오 수신
发送页面声音|傳送頁面聲音|Send device audio|Enviar audio del dispositivo|Geräteton senden|Envoyer le son de l’appareil|Invia audio del dispositivo|デバイス音声を送信|기기 오디오 전송
发送话筒声音|傳送麥克風聲音|Send microphone audio|Enviar micrófono|Mikrofonton senden|Envoyer le microphone|Invia microfono|マイク音声を送信|마이크 오디오 전송
页面声音|頁面聲音|Device audio|Audio del dispositivo|Geräteton|Son de l’appareil|Audio del dispositivo|デバイス音声|기기 오디오
话筒声音|麥克風聲音|Microphone audio|Audio del micrófono|Mikrofonton|Son du microphone|Audio del microfono|マイク音声|마이크 오디오
允许公网直连|允許公網直連|Allow Internet connections|Permitir conexiones por Internet|Internetverbindungen erlauben|Autoriser les connexions Internet|Consenti connessioni Internet|インターネット接続を許可|인터넷 연결 허용
允许公网匹配码|允許公網配對碼|Allow Internet pairing|Permitir emparejamiento por Internet|Internetkopplung erlauben|Autoriser l’association Internet|Consenti abbinamento Internet|インターネットのペアリングを許可|인터넷 페어링 허용
允许广域网直连|允許廣域網直連|Allow Internet connections|Permitir conexiones por Internet|Internetverbindungen erlauben|Autoriser les connexions Internet|Consenti connessioni Internet|インターネット接続を許可|인터넷 연결 허용
允许广域网匹配码|允許廣域網配對碼|Allow Internet pairing|Permitir emparejamiento por Internet|Internetkopplung erlauben|Autoriser l’association Internet|Consenti abbinamento Internet|インターネットのペアリングを許可|인터넷 페어링 허용
局域 IP 直连|區域 IP 直連|Local IP|IP local|Lokale IP|IP locale|IP locale|LAN IP 接続|로컬 IP 연결
局域匹配码|區域網路配對碼|Local pairing|Emparejamiento local|Lokale Kopplung|Association locale|Abbinamento locale|LAN ペアリング|로컬 페어링
广域网 IP 直连|廣域網 IP 直連|Internet IP|IP de Internet|Internet-IP|IP Internet|IP Internet|インターネット IP 接続|인터넷 IP 연결
广域网匹配码|廣域網配對碼|Internet pairing|Emparejamiento por Internet|Internetkopplung|Association Internet|Abbinamento Internet|インターネットのペアリング|인터넷 페어링
添加投屏|新增投屏|Add stream|Añadir transmisión|Stream hinzufügen|Ajouter une diffusion|Aggiungi trasmissione|配信を追加|전송 추가
开始投屏|開始投屏|Start casting|Iniciar transmisión|Übertragung starten|Démarrer la diffusion|Avvia trasmissione|送信を開始|전송 시작
更改投屏内容|變更投屏內容|Change shared content|Cambiar contenido compartido|Freigabe ändern|Modifier le contenu partagé|Cambia contenuto condiviso|共有内容を変更|공유 내용 변경
换源|切換來源|Change source|Cambiar fuente|Quelle wechseln|Changer de source|Cambia sorgente|ソースを変更|소스 변경
投屏设置|投屏設定|Casting settings|Ajustes de transmisión|Übertragungseinstellungen|Réglages de diffusion|Impostazioni trasmissione|送信設定|전송 설정
码率|位元率|Bitrate|Tasa de bits|Bitrate|Débit|Bitrate|ビットレート|비트 전송률
投屏码率|投屏位元率|Casting bitrate|Tasa de transmisión|Übertragungsbitrate|Débit de diffusion|Bitrate trasmissione|送信ビットレート|전송 비트 전송률
广播码率|廣播位元率|Broadcast bitrate|Tasa de difusión|Broadcast-Bitrate|Débit de diffusion|Bitrate diffusione|ブロードキャストのビットレート|방송 비트 전송률
帧率|影格率|Frame rate|Fotogramas por segundo|Bildrate|Fréquence d’images|Frequenza fotogrammi|フレームレート|프레임률
分辨率|解析度|Resolution|Resolución|Auflösung|Résolution|Risoluzione|解像度|해상도
分辨率诊断|解析度診斷|Resolution diagnostics|Diagnóstico de resolución|Auflösungsdiagnose|Diagnostic de résolution|Diagnostica risoluzione|解像度診断|해상도 진단
原生采集|原生擷取|Native resolution|Resolución nativa|Native Auflösung|Résolution native|Risoluzione nativa|ネイティブ解像度|기본 해상도
流畅 · 1600|流暢 · 1600|Smooth · 1600|Fluido · 1600|Flüssig · 1600|Fluide · 1600|Fluido · 1600|スムーズ · 1600|부드럽게 · 1600
高清 · 1920|高畫質 · 1920|HD · 1920|HD · 1920|HD · 1920|HD · 1920|HD · 1920|高画質 · 1920|고화질 · 1920
整个屏幕|整個螢幕|Entire screen|Pantalla completa|Gesamter Bildschirm|Écran entier|Schermo intero|画面全体|전체 화면
显示器|顯示器|Displays|Pantallas|Bildschirme|Écrans|Schermi|ディスプレイ|디스플레이
应用与窗口|應用程式與視窗|Apps and windows|Aplicaciones y ventanas|Apps und Fenster|Apps et fenêtres|App e finestre|アプリとウインドウ|앱 및 창
投屏整个应用|投屏整個應用程式|Share entire app|Compartir toda la aplicación|Gesamte App teilen|Partager toute l’app|Condividi l’intera app|アプリ全体を共有|전체 앱 공유
选择共享内容|選擇共享內容|Choose content to share|Elegir contenido|Freigabe auswählen|Choisir le contenu|Scegli contenuto|共有内容を選択|공유할 내용 선택
清除选择|清除選擇|Clear selection|Borrar selección|Auswahl löschen|Effacer la sélection|Cancella selezione|選択を解除|선택 해제
刷新应用列表|重新整理應用程式清單|Refresh app list|Actualizar aplicaciones|App-Liste aktualisieren|Actualiser les apps|Aggiorna elenco app|アプリ一覧を更新|앱 목록 새로 고침
刷新画面|重新整理畫面|Refresh image|Actualizar imagen|Bild aktualisieren|Actualiser l’image|Aggiorna immagine|映像を更新|화면 새로 고침
光标|游標|Pointer|Puntero|Zeiger|Pointeur|Puntatore|ポインタ|포인터
显示光标|顯示游標|Show pointer|Mostrar puntero|Zeiger anzeigen|Afficher le pointeur|Mostra puntatore|ポインタを表示|포인터 표시
画质与连接|畫質與連線|Quality and connection|Calidad y conexión|Qualität und Verbindung|Qualité et connexion|Qualità e connessione|画質と接続|화질 및 연결
文字清晰 · 24 Mbps / 30 fps|文字清晰 · 24 Mbps / 30 fps|Sharp text · 24 Mbps / 30 fps|Texto nítido · 24 Mbps / 30 fps|Klarer Text · 24 Mbps / 30 fps|Texte net · 24 Mbps / 30 fps|Testo nitido · 24 Mbps / 30 fps|鮮明な文字 · 24 Mbps / 30 fps|선명한 텍스트 · 24 Mbps / 30 fps
均衡 · 12 Mbps / 30 fps|均衡 · 12 Mbps / 30 fps|Balanced · 12 Mbps / 30 fps|Equilibrado · 12 Mbps / 30 fps|Ausgewogen · 12 Mbps / 30 fps|Équilibré · 12 Mbps / 30 fps|Bilanciato · 12 Mbps / 30 fps|バランス · 12 Mbps / 30 fps|균형 · 12 Mbps / 30 fps
动态流畅 · 20 Mbps / 60 fps|動態流暢 · 20 Mbps / 60 fps|Smooth motion · 20 Mbps / 60 fps|Movimiento fluido · 20 Mbps / 60 fps|Flüssige Bewegung · 20 Mbps / 60 fps|Mouvement fluide · 20 Mbps / 60 fps|Movimento fluido · 20 Mbps / 60 fps|滑らかな動き · 20 Mbps / 60 fps|부드러운 움직임 · 20 Mbps / 60 fps
3D图标|3D圖示|3D icons|Iconos 3D|3D-Symbole|Icônes 3D|Icone 3D|3D アイコン|3D 아이콘
极简皮肤|極簡佈景|Minimal|Minimalista|Minimalistisch|Minimaliste|Minimalista|ミニマル|미니멀
当前皮肤|目前佈景|Current appearance|Apariencia actual|Aktuelles Design|Apparence actuelle|Aspetto attuale|現在の外観|현재 테마
深浅色|深淺色|Appearance|Apariencia|Darstellung|Apparence|Aspetto|外観|화면 모드
跟随系统|跟隨系統|System|Sistema|System|Système|Sistema|システム設定|시스템 설정
固定浅色|固定淺色|Light|Claro|Hell|Clair|Chiaro|ライト|라이트
固定深色|固定深色|Dark|Oscuro|Dunkel|Sombre|Scuro|ダーク|다크
选择文件夹|選擇資料夾|Choose folder|Elegir carpeta|Ordner auswählen|Choisir un dossier|Scegli cartella|フォルダを選択|폴더 선택
开启自动录课|開啟自動錄課|Automatic recording|Grabación automática|Automatisch aufnehmen|Enregistrement automatique|Registrazione automatica|自動録画|자동 녹화
显示最近录课|顯示最近錄課|Show latest recording|Mostrar última grabación|Letzte Aufnahme anzeigen|Afficher le dernier enregistrement|Mostra ultima registrazione|最新の録画を表示|최근 녹화 표시
清空日志|清除記錄|Clear log|Borrar registro|Protokoll löschen|Effacer le journal|Cancella registro|ログを消去|로그 지우기
等待首帧画面…|等待首個影格…|Waiting for the first frame…|Esperando el primer fotograma…|Warten auf das erste Bild…|En attente de la première image…|In attesa del primo fotogramma…|最初のフレームを待機中…|첫 프레임 대기 중…
正在共享|正在共享|Sharing|Compartiendo|Freigabe aktiv|Partage en cours|Condivisione attiva|共有中|공유 중
正在连接画面…|正在連接畫面…|Connecting video…|Conectando vídeo…|Video wird verbunden…|Connexion vidéo…|Connessione video…|映像に接続中…|영상 연결 중…
局域网准备中…|區域網路準備中…|Preparing local network…|Preparando red local…|Lokales Netzwerk wird vorbereitet…|Préparation du réseau local…|Preparazione rete locale…|LAN を準備中…|로컬 네트워크 준비 중…
正在查找未占用的新码…|正在尋找未使用的新碼…|Finding an available code…|Buscando un código disponible…|Freier Code wird gesucht…|Recherche d’un code disponible…|Ricerca codice disponibile…|使用可能なコードを検索中…|사용 가능한 코드 찾는 중…
修改匹配码|修改配對碼|Change pairing code|Cambiar código|Kopplungscode ändern|Modifier le code|Cambia codice|コードを変更|페어링 코드 변경
匹配码 · 邀请设备连接|配對碼 · 邀請裝置連線|Pairing code · Invite devices|Código · Invitar dispositivos|Kopplungscode · Geräte einladen|Code · Inviter des appareils|Codice · Invita dispositivi|コード · デバイスを招待|페어링 코드 · 기기 초대
匹配码已占用或格式有误|配對碼已使用或格式有誤|Code in use or invalid|Código ocupado o no válido|Code belegt oder ungültig|Code utilisé ou invalide|Codice occupato o non valido|コードが使用中または無効です|사용 중이거나 올바르지 않은 코드
换一个建议|換一個建議|Suggest another|Sugerir otro|Anderen vorschlagen|Autre suggestion|Altro suggerimento|別のコードを提案|다른 코드 추천
采用建议码|採用建議碼|Use suggested code|Usar código sugerido|Vorschlag verwenden|Utiliser le code proposé|Usa codice suggerito|提案コードを使用|추천 코드 사용
采用建议码并重试|採用建議碼並重試|Use code and retry|Usar código y reintentar|Code verwenden und erneut versuchen|Utiliser et réessayer|Usa e riprova|提案コードで再試行|추천 코드로 다시 시도
重新获取建议码|重新取得建議碼|Get another code|Obtener otro código|Neuen Code abrufen|Obtenir un autre code|Ottieni un altro codice|コードを再取得|코드 다시 받기
该匹配码发生冲突，建议修改。|此配對碼發生衝突，建議修改。|This code is in use. Choose another.|Este código está ocupado. Elige otro.|Dieser Code ist belegt. Bitte ändern.|Ce code est utilisé. Choisissez-en un autre.|Codice già in uso. Scegline un altro.|このコードは使用中です。変更してください。|사용 중인 코드입니다. 다른 코드로 변경하세요.
网页接收地址|網頁接收位址|Browser receiver address|Dirección de recepción web|Web-Empfangsadresse|Adresse de réception web|Indirizzo ricezione web|ブラウザ受信アドレス|웹 수신 주소
非端到端总延迟|非端對端總延遲|Not end-to-end latency|No es latencia de extremo a extremo|Keine Ende-zu-Ende-Latenz|Pas une latence de bout en bout|Non è latenza end-to-end|エンドツーエンド遅延ではありません|종단 간 지연 시간이 아님
让画面，自由连接|讓畫面，自由連線|Connect your screens freely|Conecta tus pantallas libremente|Bildschirme frei verbinden|Connectez vos écrans librement|Collega liberamente i tuoi schermi|画面を自由につなぐ|화면을 자유롭게 연결
'''
ROWS += """
请勿利用本工具传播违法信息或侵犯他人合法权益。公网接入须经投送者确认，必要连接日志依法留存。违法使用者依法承担相应责任。|請勿利用本工具傳播違法資訊或侵害他人合法權益。公網接入須經投送者確認，必要連線記錄依法留存。違法使用者依法承擔相應責任。|Do not distribute unlawful content or infringe others’ rights. Internet access requires the sender’s approval. Necessary connection logs are retained as required by law. Users are legally responsible for unlawful use.|No difundas contenido ilícito ni vulneres derechos ajenos. El acceso por Internet requiere aprobación del emisor. Los registros necesarios se conservan conforme a la ley. El uso ilícito conlleva la responsabilidad legal correspondiente.|Keine rechtswidrigen Inhalte verbreiten oder Rechte anderer verletzen. Internetzugriff erfordert die Zustimmung des Senders. Erforderliche Verbindungsprotokolle werden gesetzeskonform gespeichert. Rechtswidrige Nutzung unterliegt der gesetzlichen Haftung.|Ne diffusez pas de contenu illicite et respectez les droits d’autrui. L’accès Internet exige l’accord de l’émetteur. Les journaux nécessaires sont conservés conformément à la loi. Toute utilisation illicite engage la responsabilité légale de son auteur.|Non diffondere contenuti illeciti né violare diritti altrui. L’accesso Internet richiede l’approvazione del mittente. I registri necessari sono conservati secondo legge. L’uso illecito comporta le responsabilità previste dalla legge.|違法な情報の配信や他者の権利侵害を禁止します。インターネット接続には送信者の承認が必要です。必要な接続ログを法令に従い保存します。違法な利用には法的責任が伴います。|불법 정보 전파 및 타인의 권리 침해를 금지합니다. 인터넷 접속에는 전송자의 승인이 필요합니다. 필요한 연결 로그는 법령에 따라 보관합니다. 불법 이용자는 해당 법적 책임을 집니다.
公网服务依法留存必要连接日志，包括来源IP、随机应用标识、审批与连接状态；客户端报告的连接时长不代表服务器核验。画面与声音不上传。详情及权利申请方式见隐私政策。|公網服務依法留存來源IP、隨機應用程式識別碼、審批及連線狀態等必要記錄；用戶端回報時長並非伺服器核驗。畫面與聲音不上傳。詳情及權利申請方式見隱私權政策。|Necessary Internet connection logs include source IP, random app ID, approval and connection status. Client-reported durations are not server-verified. Video and audio are not uploaded. See the privacy policy for details and rights requests.|Los registros necesarios incluyen IP de origen, identificador aleatorio, aprobación y estado. El servidor no verifica las duraciones informadas por el cliente. No se suben vídeo ni audio. Consulta la política de privacidad para ejercer tus derechos.|Erforderliche Internetprotokolle enthalten Quell-IP, zufällige App-ID, Freigabe und Verbindungsstatus. Vom Client gemeldete Zeitangaben sind nicht serverseitig bestätigt. Bild und Ton werden nicht hochgeladen. Details und Betroffenenrechte siehe Datenschutzerklärung.|Les journaux nécessaires incluent IP source, identifiant aléatoire, approbation et état. Les durées déclarées par le client ne sont pas vérifiées par le serveur. Aucune image ni aucun son n’est téléversé. Consultez la politique de confidentialité pour vos droits.|I registri necessari includono IP di origine, ID casuale, approvazione e stato. Le durate dichiarate dal client non sono verificate dal server. Video e audio non vengono caricati. Consulta l’informativa per dettagli e diritti.|送信元IP、ランダムなアプリID、承認・接続状態など必要なログを法令に従い保存します。クライアント報告の時間はサーバー未検証です。映像・音声はアップロードしません。詳細と権利行使はプライバシーポリシーをご覧ください。|출발지 IP, 임의 앱 ID, 승인 및 연결 상태 등 필요한 로그를 법령에 따라 보관합니다. 클라이언트가 보고한 시간은 서버에서 검증하지 않습니다. 영상과 오디오는 업로드하지 않습니다. 자세한 내용과 권리 행사 방법은 개인정보 처리방침을 확인하세요.
RTT 是网络往返时间，不是端到端画面延迟。|RTT 是網路往返時間，並非端對端畫面延遲。|RTT is network round-trip time, not end-to-end video latency.|RTT es el tiempo de ida y vuelta, no la latencia total del vídeo.|RTT ist die Netzwerk-Rundlaufzeit, nicht die gesamte Bildlatenz.|Le RTT mesure l’aller-retour réseau, pas la latence vidéo totale.|RTT è il tempo di andata e ritorno, non la latenza video totale.|RTT はネットワーク往復時間であり、映像の全遅延ではありません。|RTT는 네트워크 왕복 시간이며 전체 영상 지연 시간이 아닙니다.
RTT 为网络往返时间，约每 2 秒更新；不是端到端画面延迟。|RTT 為網路往返時間，約每 2 秒更新；並非端對端畫面延遲。|RTT measures network round-trip time, updated about every 2 seconds; it is not end-to-end video latency.|RTT mide la ida y vuelta y se actualiza cada 2 segundos; no es la latencia total del vídeo.|RTT misst die Netzwerk-Rundlaufzeit, etwa alle 2 Sekunden aktualisiert; keine gesamte Bildlatenz.|Le RTT mesure l’aller-retour réseau, actualisé environ toutes les 2 secondes, pas la latence vidéo totale.|RTT misura l’andata e ritorno di rete, aggiornata ogni 2 secondi circa, non la latenza video totale.|RTT は約2秒ごとに更新されるネットワーク往復時間で、映像の全遅延ではありません。|RTT는 약 2초마다 갱신되는 네트워크 왕복 시간이며 전체 영상 지연이 아닙니다.
共享整个屏幕，或只分享需要的应用与窗口。|共享整個螢幕，或僅分享需要的應用程式與視窗。|Share the entire screen or selected apps and windows.|Comparte toda la pantalla o aplicaciones y ventanas seleccionadas.|Gesamten Bildschirm oder ausgewählte Apps und Fenster teilen.|Partagez l’écran entier ou les apps et fenêtres choisies.|Condividi lo schermo intero o app e finestre selezionate.|画面全体、または選択したアプリやウインドウを共有します。|전체 화면 또는 선택한 앱과 창을 공유합니다.
选择屏幕、应用或窗口，连接你的另一块屏幕。|選擇螢幕、應用程式或視窗，連接另一塊螢幕。|Choose a screen, app or window to share with another display.|Elige una pantalla, aplicación o ventana para compartir.|Bildschirm, App oder Fenster zur Freigabe auswählen.|Choisissez un écran, une app ou une fenêtre à partager.|Scegli schermo, app o finestra da condividere.|共有する画面、アプリ、ウインドウを選択します。|공유할 화면, 앱 또는 창을 선택하세요.
其他项目 · 系统未提供应用名称|其他項目 · 系統未提供應用程式名稱|Other items · App name unavailable|Otros · Nombre de aplicación no disponible|Weitere · App-Name nicht verfügbar|Autres · Nom de l’app indisponible|Altro · Nome app non disponibile|その他 · アプリ名なし|기타 · 앱 이름 없음
将这台 iPad 的画面分享给 Mac 或另一台 iPad|將此 iPad 畫面分享給 Mac 或另一台 iPad|Share this iPad with a Mac or another iPad|Comparte este iPad con un Mac u otro iPad|Dieses iPad mit einem Mac oder iPad teilen|Partagez cet iPad avec un Mac ou un autre iPad|Condividi questo iPad con un Mac o un altro iPad|このiPadの画面をMacや別のiPadに共有|이 iPad 화면을 Mac 또는 다른 iPad에 공유
整屏投屏，或接收另一台设备的画面|整個螢幕投屏，或接收另一台裝置畫面|Share your screen or receive another device’s screen|Comparte tu pantalla o recibe la de otro dispositivo|Bildschirm teilen oder anderen Bildschirm empfangen|Partagez votre écran ou recevez celui d’un autre appareil|Condividi lo schermo o ricevi quello di un altro dispositivo|画面全体を共有、または別のデバイスの画面を受信|전체 화면을 공유하거나 다른 기기의 화면 수신
接收端连接这一路投屏后，会显示在这里。|接收端連接此路投屏後，會顯示於此。|Receivers of this stream appear here.|Los receptores de esta transmisión aparecen aquí.|Empfänger dieses Streams erscheinen hier.|Les récepteurs de cette diffusion apparaissent ici.|I ricevitori di questa trasmissione appaiono qui.|この配信の受信デバイスがここに表示されます。|이 전송의 수신 기기가 여기에 표시됩니다.
开始系统广播后生成局域网地址。|開始系統廣播後產生區域網路位址。|A local address is created when broadcasting starts.|La dirección local se genera al iniciar la difusión.|Lokale Adresse wird beim Broadcast-Start erstellt.|L’adresse locale est créée au début de la diffusion.|L’indirizzo locale viene creato all’avvio della trasmissione.|配信開始後にLANアドレスが作成されます。|방송을 시작하면 로컬 주소가 생성됩니다.
点击左侧系统录屏按钮|點擊左側系統錄影按鈕|Tap the system recording button on the left|Pulsa el botón de grabación a la izquierda|Systemaufnahmetaste links antippen|Touchez le bouton d’enregistrement à gauche|Tocca il pulsante di registrazione a sinistra|左のシステム録画ボタンをタップ|왼쪽 시스템 녹화 버튼을 누르세요
接收设备选择匹配码连接。投屏包含屏幕上的所有可采集内容，请先关闭不想分享的信息。|接收裝置以配對碼連線。投屏包含螢幕上所有可擷取內容，請先關閉不想分享的資訊。|Receivers connect using the pairing code. Everything capturable on screen is shared; hide private information first.|Los receptores usan el código. Se comparte todo lo capturable en pantalla; oculta antes la información privada.|Empfänger verbinden sich per Code. Alle erfassbaren Bildschirminhalte werden geteilt; private Informationen vorher schließen.|Les récepteurs utilisent le code. Tout contenu capturable est partagé ; masquez d’abord les informations privées.|I ricevitori usano il codice. Tutto ciò che può essere acquisito viene condiviso; nascondi prima i dati privati.|受信側はコードで接続します。取得可能な画面内容はすべて共有されます。私的な情報は事前に閉じてください。|수신 기기는 코드로 연결합니다. 캡처 가능한 모든 화면 내용이 공유되므로 비공개 정보를 먼저 닫으세요.
浏览器打开地址后点击开始接收；公网须开启广域网匹配码，画面不经服务器。|瀏覽器開啟位址後點擊開始接收；公網須啟用廣域網配對碼，畫面不經伺服器。|Open the address in a browser and start receiving. Internet use requires pairing and sender approval; video bypasses the server.|Abre la dirección e inicia la recepción. Por Internet se requiere emparejamiento y aprobación; el vídeo no pasa por el servidor.|Adresse im Browser öffnen und Empfang starten. Internet erfordert Kopplung und Freigabe; Video läuft direkt.|Ouvrez l’adresse et lancez la réception. Internet exige association et approbation ; la vidéo est directe.|Apri l’indirizzo e avvia la ricezione. Internet richiede abbinamento e approvazione; il video è diretto.|ブラウザでアドレスを開き受信を開始します。インターネットではペアリングと承認が必要です。映像はサーバーを経由しません。|브라우저에서 주소를 열고 수신을 시작하세요. 인터넷에서는 페어링과 승인이 필요하며 영상은 서버를 거치지 않습니다.
需要发送端可达的公网地址和映射端口；不经过配对服务器。|需要可連至投送端的公網位址及對應連接埠；不經配對伺服器。|Requires a reachable public address and mapped port. Pairing is direct; sender approval is required.|Requiere una dirección pública accesible y un puerto asignado. La aprobación del emisor es necesaria.|Erfordert erreichbare öffentliche Adresse und Portfreigabe. Direkte Kopplung mit Senderfreigabe.|Exige une adresse publique accessible et un port redirigé. Association directe avec accord de l’émetteur.|Richiede indirizzo pubblico raggiungibile e porta mappata. Abbinamento diretto con approvazione.|到達可能な公開アドレスとポート転送が必要です。直接ペアリング後、送信者の承認が必要です。|접속 가능한 공인 주소와 포트 매핑이 필요합니다. 직접 페어링 후 전송자 승인이 필요합니다.
服务器检查时未被占用；采用后请让接收端输入新码。|伺服器檢查時尚未使用；採用後請讓接收端輸入新碼。|Available when checked. Receivers must use the new code.|Disponible al comprobarlo. Los receptores deben usar el nuevo código.|Bei Prüfung frei. Empfänger müssen den neuen Code nutzen.|Disponible lors de la vérification. Utilisez le nouveau code côté réception.|Disponibile alla verifica. I ricevitori devono usare il nuovo codice.|確認時点では未使用です。受信側で新しいコードを入力してください。|확인 시 사용 가능한 코드입니다. 수신 기기에 새 코드를 입력하세요.
另一台发送设备正在使用这个匹配码。请停止那台设备的广播，或为本机换码后让接收端输入新码。|另一台投送裝置正使用此配對碼。請停止其廣播，或在本機換碼並讓接收端輸入新碼。|Another sender uses this code. Stop that broadcast or choose a new code and update the receivers.|Otro emisor usa este código. Detén su difusión o elige otro código y actualiza los receptores.|Ein anderer Sender nutzt diesen Code. Dessen Broadcast stoppen oder einen neuen Code wählen und den Empfängern mitteilen.|Un autre émetteur utilise ce code. Arrêtez sa diffusion ou changez le code et informez les récepteurs.|Un altro mittente usa questo codice. Ferma quella trasmissione o cambia codice e aggiorna i ricevitori.|別の送信デバイスがこのコードを使用中です。その配信を停止するか、新しいコードを受信側に入力してください。|다른 전송 기기가 이 코드를 사용 중입니다. 해당 방송을 중지하거나 코드를 바꾸고 수신 기기에 알려주세요.
话筒需先在系统广播面板打开麦克风；此处可随时静音或恢复。|請先於系統廣播面板開啟麥克風；此處可隨時靜音或恢復。|Enable the microphone in the system broadcast panel first. You can mute or unmute it here.|Activa primero el micrófono en el panel del sistema. Aquí puedes silenciarlo o reactivarlo.|Mikrofon zuerst im System-Broadcast aktivieren. Hier stumm schalten oder aktivieren.|Activez d’abord le microphone dans le panneau système. Vous pouvez ensuite le couper ici.|Attiva prima il microfono nel pannello di sistema. Qui puoi disattivarlo o riattivarlo.|先にシステム配信パネルでマイクをオンにしてください。ここでミュートを切り替えられます。|시스템 방송 패널에서 먼저 마이크를 켜세요. 여기서 음소거를 전환할 수 있습니다.
按最长边限制，保持画面比例。原生使用系统提供的尺寸；更高分辨率会增加设备和网络负担。设置在下次广播生效。|限制最長邊並保持比例。原生採系統尺寸；較高解析度增加裝置及網路負擔。下次廣播生效。|Limits the longest edge, preserving aspect ratio. Native uses system dimensions. Higher resolutions use more resources. Applies next broadcast.|Limita el lado mayor manteniendo la proporción. Nativo usa el tamaño del sistema. Una mayor resolución consume más recursos. Se aplica en la próxima difusión.|Längste Kante begrenzt, Seitenverhältnis bleibt. Nativ nutzt Systemmaße. Höhere Auflösung braucht mehr Ressourcen. Gilt ab nächstem Broadcast.|Limite le grand côté en conservant les proportions. Natif utilise les dimensions système. Une résolution élevée consomme davantage. Applicable à la prochaine diffusion.|Limita il lato maggiore mantenendo le proporzioni. Nativo usa le dimensioni di sistema. Risoluzioni elevate richiedono più risorse. Vale dalla prossima trasmissione.|縦横比を保ち長辺を制限します。ネイティブはシステムの寸法を使用します。高解像度は負荷が増えます。次回の配信から適用されます。|비율을 유지하며 긴 변을 제한합니다. 기본 해상도는 시스템 크기를 사용합니다. 고해상도는 부하를 늘립니다. 다음 방송부터 적용됩니다.
在系统弹窗中确认开始后，可以切换到其他应用继续投屏。系统不允许静默启动录屏；受保护的视频可能不会显示。声音可分别选择页面与话筒。|在系統視窗確認開始後，可切換其他應用程式繼續投屏。不可靜默啟動錄影；受保護影片可能不顯示。可分別選擇頁面與麥克風聲音。|Confirm in the system dialog, then switch apps while sharing. Recording cannot start silently. Protected video may be hidden. Device and microphone audio are separate options.|Confirma en el diálogo del sistema y cambia de aplicación. No hay grabación silenciosa. Los vídeos protegidos pueden ocultarse. El audio del dispositivo y del micrófono se eligen por separado.|Im Systemdialog bestätigen, dann Apps wechseln. Aufnahme startet nicht unbemerkt. Geschütztes Video kann ausgeblendet sein. Geräte- und Mikrofonton sind separat wählbar.|Confirmez dans le dialogue système, puis changez d’app. Pas d’enregistrement silencieux. Les vidéos protégées peuvent être masquées. Sons de l’appareil et du micro sont séparés.|Conferma nel dialogo di sistema, poi cambia app. La registrazione non parte di nascosto. I video protetti potrebbero essere nascosti. Audio dispositivo e microfono sono separati.|システムで開始を確認後、他のアプリに切り替えられます。録画は無断で開始しません。保護された映像は表示されない場合があります。デバイスとマイクの音声を個別に選べます。|시스템 창에서 시작을 확인한 후 다른 앱으로 전환할 수 있습니다. 녹화는 몰래 시작되지 않습니다. 보호된 영상은 표시되지 않을 수 있습니다. 기기와 마이크 오디오는 따로 선택합니다.
RTT是设备间网络往返时间；接收处理是最近采样期间每帧的缓冲与解码平均耗时。均不是端到端总延迟；无有效样本时显示—。|RTT為裝置間網路往返時間；接收處理為近期每影格緩衝與解碼平均耗時。皆非端對端總延遲；無有效樣本時顯示—。|RTT is network round-trip time. Receive processing averages per-frame buffering and decoding. Neither is total end-to-end latency. A dash means no valid sample.|RTT mide la ida y vuelta. El procesamiento promedia búfer y decodificación por fotograma. Ninguno es la latencia total. Un guion indica que no hay muestras válidas.|RTT ist die Netzwerk-Rundlaufzeit. Empfangsverarbeitung mittelt Pufferung und Dekodierung je Bild. Beides ist keine Gesamtlatenz. Ein Strich bedeutet: kein gültiger Messwert.|RTT : aller-retour réseau. Traitement : moyenne de mise en mémoire et décodage par image. Aucun ne mesure la latence totale. Un tiret indique l’absence de mesure valide.|RTT indica l’andata e ritorno di rete. L’elaborazione media buffer e decodifica per fotogramma. Nessuno indica la latenza totale. Il trattino indica un campione non disponibile.|RTTはネットワーク往復時間です。受信処理はフレームごとのバッファとデコードの平均です。いずれも全遅延ではありません。有効な値がない場合は—を表示します。|RTT는 네트워크 왕복 시간입니다. 수신 처리는 프레임당 버퍼링과 디코딩 평균입니다. 둘 다 전체 지연 시간이 아닙니다. 유효한 표본이 없으면 —가 표시됩니다.
"""
ROWS += """
开始接收|開始接收|Start receiving|Iniciar recepción|Empfang starten|Démarrer la réception|Avvia ricezione|受信を開始|수신 시작
等待连接|等待連線|Waiting for connection|Esperando conexión|Warten auf Verbindung|En attente de connexion|In attesa di connessione|接続待ち|연결 대기 중
开启声音|開啟聲音|Enable sound|Activar sonido|Ton einschalten|Activer le son|Attiva audio|音声をオン|소리 켜기
关闭声音|關閉聲音|Mute|Silenciar|Stumm schalten|Couper le son|Disattiva audio|消音|음소거
全屏观看|全螢幕觀看|Full screen|Pantalla completa|Vollbild|Plein écran|Schermo intero|全画面|전체 화면
正在连接发送端…|正在連線投送端…|Connecting to sender…|Conectando al emisor…|Verbindung zum Sender…|Connexion à l’émetteur…|Connessione al mittente…|送信側に接続中…|전송자에 연결 중…
接入申请已提交，等待投送者接受…|已提交接入申請，等待投送者接受…|Request submitted. Waiting for sender approval…|Solicitud enviada. Esperando aprobación…|Anfrage gesendet. Warten auf Freigabe…|Demande envoyée. En attente d’approbation…|Richiesta inviata. In attesa di approvazione…|接続を申請しました。送信者の承認待ち…|접속 요청을 보냈습니다. 전송자 승인 대기 중…
已连接 · 设备直接传输|已連線 · 裝置直接傳輸|Connected · Direct device transfer|Conectado · Transmisión directa|Verbunden · Direkte Übertragung|Connecté · Transfert direct|Connesso · Trasferimento diretto|接続済み · デバイス間転送|연결됨 · 기기 간 직접 전송
已断开|已中斷連線|Disconnected|Desconectado|Getrennt|Déconnecté|Disconnesso|切断済み|연결 해제됨
已连接|已連線|Connected|Conectado|Verbunden|Connecté|Connesso|接続済み|연결됨
未连接|未連線|Not connected|Sin conexión|Nicht verbunden|Non connecté|Non connesso|未接続|연결되지 않음
连接中...|連線中...|Connecting...|Conectando...|Verbindung wird hergestellt...|Connexion...|Connessione...|接続中...|연결 중...
等待设备连接|等待裝置連線|Waiting for devices|Esperando dispositivos|Warten auf Geräte|En attente d’appareils|In attesa di dispositivi|デバイス接続待ち|기기 연결 대기 중
正在读取连接信息…|正在讀取連線資訊…|Reading connection details…|Leyendo conexión…|Verbindungsdetails werden gelesen…|Lecture de la connexion…|Lettura connessione…|接続情報を取得中…|연결 정보 읽는 중…
配对成功，正在检查设备直连…|配對成功，正在檢查裝置直連…|Paired. Checking direct connection…|Emparejado. Comprobando conexión directa…|Gekoppelt. Direkte Verbindung wird geprüft…|Associé. Vérification de la connexion directe…|Abbinato. Verifica connessione diretta…|ペアリング完了。直接接続を確認中…|페어링 완료. 직접 연결 확인 중…
请输入6至36位数字匹配码|請輸入6至36位數字配對碼|Enter a 6–36 digit pairing code|Introduce un código de 6–36 dígitos|6–36-stelligen Kopplungscode eingeben|Saisissez un code de 6 à 36 chiffres|Inserisci un codice di 6–36 cifre|6～36桁のコードを入力してください|숫자 6~36자리 코드를 입력하세요
接入申请已超时|接入申請已逾時|Access request timed out|Solicitud caducada|Anfrage abgelaufen|Demande expirée|Richiesta scaduta|接続申請がタイムアウトしました|접속 요청 시간 초과
投送者拒绝申请或连接已达上限|投送者拒絕申請或連線已達上限|Request declined or connection limit reached|Solicitud rechazada o límite alcanzado|Anfrage abgelehnt oder Limit erreicht|Demande refusée ou limite atteinte|Richiesta rifiutata o limite raggiunto|申請が拒否されたか接続上限に達しました|요청이 거절되었거나 연결 한도에 도달했습니다
请更新投送端以启用公网接入审批|請更新投送端以啟用公網審批|Update the sender to enable Internet approval|Actualiza el emisor para habilitar la aprobación|Sender für Internetfreigaben aktualisieren|Mettez l’émetteur à jour pour l’approbation Internet|Aggiorna il mittente per approvare l’accesso Internet|送信側を更新して接続承認を有効にしてください|전송 앱을 업데이트하여 인터넷 승인을 활성화하세요
"""
ROWS += """
语言|語言|Language|Idioma|Sprache|Langue|Lingua|言語|언어
设置|設定|Settings|Ajustes|Einstellungen|Réglages|Impostazioni|設定|설정
完成|完成|Done|Listo|Fertig|Terminé|Fine|完了|완료
皮肤|佈景|Theme|Tema|Design|Thème|Tema|テーマ|테마
外观|外觀|Appearance|Apariencia|Darstellung|Apparence|Aspetto|外観|화면 모드
"""
ROWS += """
连接密码|連線密碼|Connection password|Contraseña de conexión|Verbindungspasswort|Mot de passe de connexion|Password di connessione|接続パスワード|연결 비밀번호
连接密码（6–64位）|連線密碼（6–64字元）|Connection password (6–64 characters)|Contraseña (6–64 caracteres)|Passwort (6–64 Zeichen)|Mot de passe (6–64 caractères)|Password (6–64 caratteri)|接続パスワード（6～64文字）|연결 비밀번호(6~64자)
设置连接密码|設定連線密碼|Set connection password|Establecer contraseña|Passwort festlegen|Définir le mot de passe|Imposta password|接続パスワードを設定|연결 비밀번호 설정
申请文字（必填，最多200字）|申請文字（必填，最多200字）|Request message (required, up to 200 characters)|Solicitud (obligatoria, hasta 200 caracteres)|Anfrage (erforderlich, bis 200 Zeichen)|Message requis (200 caractères maximum)|Messaggio richiesto (massimo 200 caratteri)|申請メッセージ（必須、200文字まで）|신청 메시지(필수, 최대 200자)
邀请链接或编号|邀請連結或編號|Invitation link or ID|Enlace o ID de invitación|Einladungslink oder ID|Lien ou identifiant d’invitation|Link o ID invito|招待リンクまたは番号|초대 링크 또는 번호
邀请编号|邀請編號|Invitation ID|ID de invitación|Einladungs-ID|Identifiant d’invitation|ID invito|招待番号|초대 번호
局域邀请|區域網路邀請|LAN invitation|Invitación local|LAN-Einladung|Invitation locale|Invito locale|LAN 招待|로컬 초대
公网邀请|公網邀請|Internet invitation|Invitación por Internet|Internet-Einladung|Invitation Internet|Invito Internet|インターネット招待|인터넷 초대
公网地址|公網位址|Public IP address|Dirección IP pública|Öffentliche IP-Adresse|Adresse IP publique|Indirizzo IP pubblico|公開 IP アドレス|공인 IP 주소
接入申请|接入申請|Access request|Solicitud de acceso|Zugriffsanfrage|Demande d’accès|Richiesta di accesso|接続申請|접속 신청
请先在设置中设置连接密码|請先在設定中設定連線密碼|Set a connection password in Settings first|Configura primero una contraseña en Ajustes|Zuerst ein Passwort in den Einstellungen festlegen|Définissez d’abord un mot de passe dans les réglages|Imposta prima una password nelle impostazioni|先に設定で接続パスワードを設定してください|먼저 설정에서 연결 비밀번호를 지정하세요
邀请链接不含密码；请另行告知接收者连接密码|邀請連結不含密碼；請另外告知接收者連線密碼|Invitations contain no password. Share the password separately.|La invitación no contiene contraseña. Compártela por separado.|Einladungen enthalten kein Passwort. Passwort separat mitteilen.|L’invitation ne contient aucun mot de passe. Communiquez-le séparément.|L’invito non contiene la password. Comunicala separatamente.|招待リンクにパスワードは含まれません。別途伝えてください。|초대 링크에는 비밀번호가 없습니다. 별도로 알려주세요.
"""
strings = {}
for row in ROWS.strip().splitlines():
    if not row.strip(): continue
    fields = row.split('|')
    assert len(fields) == 9, fields[0]
    key, *values = fields
    strings[key] = {'localizations': {lang: {'stringUnit': {'state':'translated', 'value':value}} for lang, value in zip(LANGUAGES, values)}}
(ROOT / 'Shared/Localizable.xcstrings').write_text(json.dumps({'sourceLanguage':'zh-Hans','strings':strings,'version':'1.0'}, ensure_ascii=False, indent=2)+'\n')
print(f'Generated {len(strings)} entries in {len(LANGUAGES)} languages')

# Browser uses only connection and notice strings; keep each static asset bounded.
web_keys = ["连接密码", "申请文字（必填，最多200字）", "邀请链接或编号", "匹配码", "开始接收", "断开", "等待连接", "开启声音", "关闭声音", "全屏观看", "诊断", "隐私政策", "连接诊断", "接收工作台", "正在连接发送端…", "接入申请已提交，等待投送者接受…", "已连接 · 设备直接传输", "已断开", "配对成功，正在检查设备直连…", "请输入6至36位数字匹配码", "接入申请已超时", "投送者拒绝申请或连接已达上限", "请更新投送端以启用公网接入审批", "请勿利用本工具传播违法信息或侵犯他人合法权益。公网接入须经投送者确认，必要连接日志依法留存。违法使用者依法承担相应责任。"]
web = {key: [strings[key]['localizations'][lang]['stringUnit']['value'] for lang in LANGUAGES] for key in web_keys}
(ROOT / 'Server/Web/receiver-i18n.js').write_text("'use strict';window.ToupingI18n=" + json.dumps({'languages':LANGUAGES,'strings':web}, ensure_ascii=False, separators=(',',':')) + ';\n')
