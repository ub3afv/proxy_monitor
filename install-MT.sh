#!/bin/bash
# ============================================================================
# Multi-Protocol Proxy Monitor v9.0 — ПОЛНАЯ УСТАНОВКА
# ✅ Пароль в админке • ✅ 24 часа интервал • ✅ Кнопка обновления
# ============================================================================

set -e

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# Конфигурация
INSTALL_DIR="/opt/proxy_monitor"
DATA_DIR="/var/www/proxy_monitor"
SERVICE_NAME="proxy-monitor"
API_SERVICE="proxy-admin-api"
NGINX_USER="www-data"
NGINX_GROUP="www-data"
DOMAIN=""
EMAIL=""
CUSTOM_PORT=""
ADMIN_USER=""
ADMIN_PASS=""

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   🌐 Multi-Protocol Proxy Monitor v9.0                   ║"
echo "║   ✅ Пароль в админке • 24ч интервал • Ручное обновление ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$EUID" -ne 0 ]; then echo -e "${RED}❌ sudo ./install.sh${NC}"; exit 1; fi

source /etc/os-release 2>/dev/null || true
echo -e "${CYAN}📊 Система: ${GREEN}$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Linux')${NC}"

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${BLUE}[→]${NC} $1"; }

# Проверка пользователя
if ! id -u "$NGINX_USER" >/dev/null 2>&1; then
    if id -u nginx >/dev/null 2>&1; then NGINX_USER="nginx"; NGINX_GROUP="nginx"; log_warn "Используем: $NGINX_USER"
    else log_error "Пользователь веб-сервера не найден!"; exit 1; fi
fi

# ============================================================================
# Настройка
# ============================================================================
echo ""; echo -e "${YELLOW}═══ Настройка ═══${NC}"
read -p "Домен (Enter для IP): " DOMAIN
read -p "Порт [8080]: " CUSTOM_PORT
read -p "Email для SSL (опционально): " EMAIL

CUSTOM_PORT=${CUSTOM_PORT:-8080}
SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
DOMAIN=${DOMAIN:-$SERVER_IP}

echo ""; echo -e "${YELLOW}═══ Админ-панель ═══${NC}"
read -p "Логин [admin]: " ADMIN_USER
read -s -p "Пароль: " ADMIN_PASS; echo ""
read -s -p "Подтвердите пароль: " ADMIN_PASS2; echo ""

if [ "$ADMIN_PASS" != "$ADMIN_PASS2" ]; then log_error "Пароли не совпадают!"; exit 1; fi
ADMIN_USER=${ADMIN_USER:-admin}

log_info "Веб: ${YELLOW}http://$DOMAIN:$CUSTOM_PORT${NC}"
log_info "Админ: ${YELLOW}http://$DOMAIN:$CUSTOM_PORT/admin${NC} (login: $ADMIN_USER)"

echo ""; read -p "Продолжить? [y/N]: " -n 1 -r; echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then log_warn "Отменено"; exit 0; fi

# ============================================================================
# 1. Обновление и пакеты
# ============================================================================
log_step "Обновление..."
apt update -qq 2>/dev/null && apt upgrade -y -qq 2>/dev/null || apt update && apt upgrade -y
log_step "Пакеты..."
apt install -y -qq python3 python3-venv python3-pip nginx curl wget jq apache2-utils openssl 2>/dev/null || apt install -y python3 python3-venv python3-pip nginx curl wget jq apache2-utils openssl

# ============================================================================
# 2. Python venv
# ============================================================================
log_step "Python venv..."
mkdir -p "$INSTALL_DIR"; VENV_DIR="$INSTALL_DIR/venv"
python3 -m venv "$VENV_DIR" 2>/dev/null || true
source "$VENV_DIR/bin/activate" 2>/dev/null || true
pip install --upgrade pip --quiet 2>/dev/null || true
pip install --quiet requests qrcode[pil] geoip2 Pillow 2>/dev/null || pip install --quiet --break-system-packages requests qrcode[pil] geoip2 Pillow 2>/dev/null || true
deactivate 2>/dev/null || true

# ============================================================================
# 3. Конфигурация (ЧИСТЫЕ URL)
# ============================================================================
log_step "Конфигурация..."
mkdir -p "$DATA_DIR/qr_codes" "$DATA_DIR/logs"

cat > "$INSTALL_DIR/config.json" << CFGEOF
{
  "admin_user": "$ADMIN_USER",
  "sources": {
    "mtproto": "https://raw.githubusercontent.com/ALIILAPRO/MTProtoProxy/refs/heads/main/mtproto.txt",
    "vless": "https://raw.githubusercontent.com/zieng2/wl/main/vless_lite.txt",
    "vmess": "https://raw.githubusercontent.com/whoahaow/rjsxrd/refs/heads/main/githubmirror/split-by-protocols/vmess-secure.txt"
  },
  "data_dir": "/var/www/proxy_monitor",
  "qr_dir": "qr_codes",
  "geoip_db": "GeoLite2-Country.mmdb",
  "max_vmess": 150,
  "timeout": 2
}
CFGEOF

ln -sf "$INSTALL_DIR/config.json" "$DATA_DIR/config.json"
chmod 640 "$INSTALL_DIR/config.json"
chown -R "${NGINX_USER}:${NGINX_GROUP}" "$INSTALL_DIR" "$DATA_DIR"

# ============================================================================
# 4. proxy_monitor.py (с поддержкой ручного обновления)
# ============================================================================
log_step "proxy_monitor.py..."
cat > "$INSTALL_DIR/proxy_monitor.py" << 'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Multi-Protocol Proxy Monitor v9.0"""
import requests,re,os,json,hashlib,qrcode,socket,time,signal,sys,base64
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
try:
    import geoip2.database;GEOIP_AVAILABLE=True
except:GEOIP_AVAILABLE=False

CONFIG_PATH=os.path.join(os.path.dirname(os.path.abspath(__file__)),'config.json')
with open(CONFIG_PATH,'r')as f:CONFIG=json.load(f)

COUNTRY_EMOJI={'US':'🇺🇸','GB':'🇬🇧','DE':'🇩🇪','FR':'🇫🇷','NL':'🇳🇱','RU':'🇷🇺','UA':'🇺🇦','BY':'🇧🇾','KZ':'🇰🇿','PL':'🇵🇱','FI':'🇫🇮','SE':'🇸🇪','NO':'🇳🇴','DK':'🇩🇰','IT':'🇮🇹','ES':'🇪🇸','PT':'🇵🇹','CH':'🇨🇭','AT':'🇦🇹','BE':'🇧🇪','CZ':'🇨🇿','SK':'🇸🇰','HU':'🇭🇺','RO':'🇷🇴','BG':'🇧🇬','GR':'🇬🇷','TR':'🇹🇷','IL':'🇮🇱','AE':'🇦🇪','SA':'🇸🇦','IN':'🇮🇳','CN':'🇨🇳','JP':'🇯🇵','KR':'🇰🇷','SG':'🇸🇬','HK':'🇭🇰','TW':'🇹🇼','AU':'🇦🇺','NZ':'🇳🇿','CA':'🇨🇦','BR':'🇧🇷','MX':'🇲🇽','AR':'🇦🇷','CL':'🇨🇱','CO':'🇨🇴','ZA':'🇿🇦','EG':'🇪🇬','NG':'🇳🇬','KE':'🇰🇪','VN':'🇻🇳','TH':'🇹🇭','MY':'🇲🇾','ID':'🇮🇩','PH':'🇵🇭','PK':'🇵🇰','IR':'🇮🇷','IQ':'🇮🇶','AF':'🇦🇫','UZ':'🇺🇿','TM':'🇹🇲','TJ':'🇹🇯','KG':'🇰🇬','AM':'🇦🇲','AZ':'🇦🇿','GE':'🇬🇪','MD':'🇲🇩','LT':'🇱🇹','LV':'🇱🇻','EE':'🇪🇪','HR':'🇭🇷','SI':'🇸🇮','RS':'🇷🇸','BA':'🇧🇦','ME':'🇲🇪','MK':'🇲🇰','AL':'🇦🇱','LU':'🇱🇺','IS':'🇮🇸','IE':'🇮🇪','MT':'🇲🇹','CY':'🇨🇾','Unknown':'🌍'}

def log(msg):
    ts=datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{ts}] {msg}")
    try:
        with open(os.path.join(CONFIG['data_dir'],'monitor.log'),'a')as f:f.write(f"[{ts}] {msg}\n")
    except:pass

def fetch(url):
    try:
        r=requests.get(url.strip(),timeout=30)
        return r.text if r.status_code==200 else None
    except:return None

def parse_mtproto(t):
    links=re.findall(r'(tg://proxy\?[^\s<>"\']+)',t)
    links+=re.findall(r'(https://t\.me/proxy\?[^\s<>"\']+)',t)
    return list(set(links))

def parse_vless(t):return list(set(re.findall(r'(vless://[^\s<>"\']+)',t)))

def parse_vmess(t):
    result=[]
    for link in re.findall(r'(vmess://[^\s<>"\']+)',t):
        try:
            enc=link[8:].strip()
            if enc.startswith('{'):result.append(link);continue
            enc+='='*(4-len(enc)%4)if len(enc)%4 else''
            json.loads(base64.b64decode(enc).decode())
            result.append(f"vmess://{base64.b64decode(enc).decode()}")
        except:result.append(link)
    return list(set(result))

def resolve_ip(h):
    if re.match(r'^\d+\.\d+\.\d+\.\d+$',str(h)):return h
    try:return socket.getaddrinfo(h,None,socket.AF_INET,socket.SOCK_STREAM,timeout=2)[0][4][0]
    except:return None

def check_proxy(link,ptype):
    try:
        srv,prt=None,None
        if ptype=='mtproto'and'server='in link and'port='in link:
            q=link.split('?')[1]if'?'in link else''
            for p in q.split('&'):
                if p.startswith('server='):srv=p.split('=')[1]
                if p.startswith('port='):prt=int(p.split('=')[1])
        elif ptype=='vless':
            u=urlparse(link);srv,prt=u.hostname,u.port
        elif ptype=='vmess':
            try:
                u=urlparse(link);n=u.netloc
                d=json.loads(n if n.startswith('{')else base64.b64decode(n+'='*(4-len(n)%4)).decode())
                srv,prt=d.get('add'),d.get('port')
            except:pass
        if not srv or not prt:return False,0
        resolved=resolve_ip(srv)
        if not resolved:return False,0
        t0=time.time()
        with socket.socket(socket.AF_INET,socket.SOCK_STREAM)as s:
            s.settimeout(CONFIG['timeout'])
            return(s.connect_ex((resolved,int(prt)))==0),round((time.time()-t0)*1000,2)
    except:return False,0

def get_country(ip):
    if not ip:return'Unknown','🌍'
    if GEOIP_AVAILABLE:
        db=os.path.join(CONFIG['data_dir'],CONFIG['geoip_db'])
        if os.path.exists(db):
            try:
                with geoip2.database.Reader(db)as r:
                    c=r.country(ip).country.iso_code
                    if c:return c,COUNTRY_EMOJI.get(c,'🌍')
            except:pass
    try:
        cc=requests.get(f"http://ip-api.com/json/{ip}?fields=countryCode",timeout=3).json().get('countryCode')
        if cc and len(cc)==2:return cc.upper(),COUNTRY_EMOJI.get(cc.upper(),'🌍')
    except:pass
    return'Unknown','🌍'

def gen_qr(link,fname):
    try:
        d=os.path.join(CONFIG['data_dir'],CONFIG['qr_dir'])
        Path(d).mkdir(parents=True,exist_ok=True)
        fp=os.path.join(d,fname)
        qr=qrcode.QRCode(version=1,box_size=11,border=4)
        qr.add_data(link);qr.make(fit=True)
        qr.make_image(fill_color="black",back_color="white").save(fp)
        os.chmod(fp,0o644)
        return True
    except:return False

def gen_html(links,total,ptype,lc):
    icons,names={'mtproto':'✈️','vless':'🔷','vmess':'🔶'},{'mtproto':'MTProto','vless':'VLESS','vmess':'VMess'}
    links.sort(key=lambda x:(x.get('country_code','ZZ'),x.get('response_time',9999)))
    countries={}
    for l in links:
        cc=l.get('country_code','Unknown')
        if cc not in countries:countries[cc]={'emoji':COUNTRY_EMOJI.get(cc,'🌍'),'count':0}
        countries[cc]['count']+=1
    items=''
    for l in links:
        flag=COUNTRY_EMOJI.get(l.get('country_code','Unknown'),'🌍')
        items+=f'''<div class="pc" data-country="{l.get('country_code','Unknown')}">
        <div class="ch"><span class="flag">{flag}</span><span class="cc">{l.get('country_code','?')}</span><span class="rt">⚡{l.get('response_time',0)}ms</span></div>
        <div class="cb"><div class="srv">🌐{l.get('server','?')}:{l.get('port','?')}</div><div class="lnk" title="{l['link']}">{l["link"][:55]}{'...'if len(l['link'])>55 else''}</div></div>
        <div class="cqr"><img src="/qr_codes/{l['qr_file']}"class="qr"loading="lazy"><a href="/qr_codes/{l['qr_file']}"download class="qr-dl">⬇️</a></div>
        <div class="ca"><a href="{l['link']}"class="btn">📱Подключить</a></div></div>'''
    cf=''.join(f'<button class="fb"data-cc="{cc}"onclick="fc(\'{cc}\')">{COUNTRY_EMOJI.get(cc,"🌍")}{cc}({d["count"]})</button>'for cc,d in sorted(countries.items(),key=lambda x:x[1]['count'],reverse=True))
    nav=f'''<div class="nav"><a href="/index.html"class="nb{' a'if ptype=='mtproto'else''}">✈️MTProto</a><a href="/vless.html"class="nb{' a'if ptype=='vless'else''}">🔷VLESS</a><a href="/vmess.html"class="nb{' a'if ptype=='vmess'else''}">🔶VMess</a><a href="/admin"class="nb"style="background:#e74c3c">⚙️Админ</a></div>'''
    js="""<script>function fc(cc){document.querySelectorAll('.fb').forEach(function(b){b.classList.remove('a')});if(event&&event.target)event.target.classList.add('a');document.querySelectorAll('.pc').forEach(function(c){c.style.display=(cc==='all'||c.dataset.country===cc)?'flex':'none'})}</script>"""
    css="""<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:linear-gradient(135deg,#667eea,#764ba2);min-height:100vh;padding:20px}.c{max-width:1400px;margin:0 auto;background:#fff;border-radius:20px;padding:25px;box-shadow:0 20px 60px rgba(0,0,0,.3)}h1{color:#333;margin:0 0 15px;font-size:2em;display:flex;align-items:center;gap:10px}.st{background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;padding:20px;border-radius:12px;margin:20px 0;display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:15px;text-align:center}.sv{font-size:2em;font-weight:700;display:block}.sl{font-size:.9em;opacity:.95}.nav{display:flex;gap:10px;margin:20px 0;flex-wrap:wrap}.nb{padding:12px 24px;background:#667eea;color:#fff;text-decoration:none;border-radius:8px;font-weight:600}.nb:hover{transform:translateY(-2px);box-shadow:0 5px 15px rgba(102,126,234,.4)}.nb.a{background:#11998e}.cf{background:#f8f9fa;padding:15px;border-radius:10px;margin:20px 0;display:flex;flex-wrap:wrap;gap:8px}.fb{padding:8px 16px;background:#fff;border:2px solid #e9ecef;border-radius:20px;cursor:pointer}.fb:hover{border-color:#667eea}.fb.a{background:#667eea;color:#fff}.pg{display:grid;grid-template-columns:repeat(3,1fr);gap:20px;margin:20px 0}.pc{background:#fff;border:2px solid #e9ecef;border-radius:12px;padding:15px;display:flex;flex-direction:column}.pc:hover{border-color:#667eea;box-shadow:0 8px 25px rgba(102,126,234,.2);transform:translateY(-3px)}.ch{display:flex;justify-content:space-between;align-items:center;padding-bottom:10px;border-bottom:1px solid #f0f0f0;margin-bottom:10px}.flag{font-size:2em}.cc{font-weight:700;color:#667eea}.rt{color:#11998e;font-weight:700;font-size:.9em}.cb{flex:1}.srv{font-size:.95em;color:#667eea;font-weight:600;margin-bottom:5px}.lnk{font-family:"Courier New",monospace;font-size:.75em;color:#666;background:#f8f9fa;padding:8px;border-radius:6px;word-break:break-all}.cqr{display:flex;justify-content:center;align-items:center;gap:10px;margin:10px 0;position:relative}.qr{width:132px;height:132px;border:3px solid #e9ecef;border-radius:8px}.qr-dl{position:absolute;bottom:5px;right:5px;background:#11998e;color:#fff;width:32px;height:32px;border-radius:50%;display:flex;align-items:center;justify-content:center;text-decoration:none;opacity:0;transition:opacity.3s}.cqr:hover.qr-dl{opacity:1}.ca{margin-top:10px}.btn{display:block;width:100%;padding:12px;background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;text-decoration:none;border-radius:8px;text-align:center;font-weight:600}@media(max-width:1200px){.pg{grid-template-columns:repeat(2,1fr)}}@media(max-width:768px){.pg{grid-template-columns:1fr}h1{font-size:1.5em}.st{grid-template-columns:repeat(2,1fr)}}}</style>"""
    return f'''<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport"content="width=device-width"><title>{names[ptype]}</title>{css}</head><body><div class="c"><h1>{icons[ptype]}{names[ptype]}</h1><div class="st"><div><span class="sv">{total}</span><span class="sl">Всего</span></div><div><span class="sv">{len(links)}</span><span class="sl">Рабочих✅</span></div><div><span class="sv">{len(countries)}</span><span class="sl">Стран🌍</span></div><div><span class="sv">{lc}</span><span class="sl">Проверка</span></div></div>{nav}<div class="cf"><button class="fb a"data-cc="all"onclick="fc('all')">🌍Все({len(links)})</button>{cf}</div><div class="pg"id="pg">{items}</div></div>{js}</body></html>'''

def download_geoip():
    db=os.path.join(CONFIG['data_dir'],CONFIG['geoip_db'])
    if os.path.exists(db)and(datetime.now().timestamp()-os.path.getmtime(db))<7*86400:return db
    try:
        log("📥GeoIP...");r=requests.get("https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-Country.mmdb",timeout=120,stream=True)
        with open(db,'wb')as f:
            for chunk in r.iter_content(chunk_size=8192):f.write(chunk)
        log("✅GeoIP");return db
    except:return None

def run_check():
    """Основная функция проверки прокси"""
    log("===Proxy Monitor v9.0===")
    Path(CONFIG['data_dir']).mkdir(parents=True,exist_ok=True)
    Path(os.path.join(CONFIG['data_dir'],CONFIG['qr_dir'])).mkdir(exist_ok=True)
    if GEOIP_AVAILABLE:download_geoip()
    hist={}
    try:
        with open(os.path.join(CONFIG['data_dir'],CONFIG['history_file']),'r')as f:hist=json.load(f)
    except:pass
    for pt,url in CONFIG['sources'].items():
        log(f"\n[{pt.upper()}]")
        content=fetch(url)
        if not content:
            log(f"⚠️Skip {pt}");fn='index.html'if pt=='mtproto'else f'{pt}.html'
            with open(os.path.join(CONFIG['data_dir'],fn),'w')as f:f.write(gen_html([],0,pt,datetime.now().strftime('%Y-%m-%d')))
            continue
        links={'mtproto':parse_mtproto,'vless':parse_vless,'vmess':parse_vmess}[pt](content)
        if pt=='vmess'and len(links)>CONFIG['max_vmess']:links=links[:CONFIG['max_vmess']]
        log(f"Найдено:{len(links)}");valid=[]
        for i,link in enumerate(links):
            if i%20==0 and i>0:log(f"  {i}/{len(links)}...")
            ip=None
            if pt=='mtproto'and'server='in link:
                for p in link.split('?')[1].split('&'):
                    if p.startswith('server=')and re.match(r'^\d+\.\d+\.\d+\.\d+$',p.split('=')[1]):ip=p.split('=')[1]
            elif pt=='vless':
                try:ip=urlparse(link).hostname
                except:pass
            elif pt=='vmess':
                try:
                    u=urlparse(link);n=u.netloc
                    d=json.loads(n if n.startswith('{')else base64.b64decode(n+'='*(4-len(n)%4)).decode())
                    if re.match(r'^\d+\.\d+\.\d+\.\d+$',str(d.get('add',''))):ip=d.get('add')
                except:pass
            cc,em=get_country(ip);ok,rt=check_proxy(link,pt)
            if ok:
                h=hashlib.md5(link.encode()).hexdigest()[:12];qf=f"{pt}_{h}.png"
                if gen_qr(link,qf):
                    port='?'
                    if pt=='mtproto':
                        for p in link.split('?')[1].split('&'):
                            if p.startswith('port='):port=p.split('=')[1];break
                    elif pt=='vless':
                        try:port=str(urlparse(link).port)
                        except:pass
                    elif pt=='vmess':
                        try:
                            u=urlparse(link);n=u.netloc
                            d=json.loads(n if n.startswith('{')else base64.b64decode(n+'='*(4-len(n)%4)).decode())
                            port=str(d.get('port','?'))
                        except:pass
                    valid.append({'link':link,'qr_file':qf,'checked_at':datetime.now().isoformat(),'country_code':cc,'country_emoji':em,'server':ip or'?','port':port,'response_time':rt})
        hist[pt]={'last_check':datetime.now().isoformat(),'valid_links':valid,'total_count':len(links)}
        lc=hist[pt]['last_check'].replace('T',' ').split('.')[0];fn='index.html'if pt=='mtproto'else f'{pt}.html'
        with open(os.path.join(CONFIG['data_dir'],fn),'w')as f:f.write(gen_html(valid,len(links),pt,lc))
        log(f"✅{fn}:{len(valid)}/{len(links)}")
    with open(os.path.join(CONFIG['data_dir'],CONFIG['history_file']),'w')as f:json.dump(hist,f,indent=2,ensure_ascii=False)
    log("\n===Готово!===")

def handle_admin_api(method,data=None):
    """API обработчик для админ-панели"""
    if method=='GET'and data=='config':
        # Возвращаем текущий config
        with open(CONFIG_PATH,'r')as f:
            return json.dumps({'ok':True,'config':json.load(f)})
    elif method=='POST'and data=='update':
        # Ручное обновление
        log("🔄 Ручное обновление запрошено")
        run_check()
        return json.dumps({'ok':True,'message':'✅ Проверка завершена!'})
    elif method=='POST'and isinstance(data,dict)and'sources'in data:
        # Сохранение новых URL
        with open(CONFIG_PATH,'r')as f:
            config=json.load(f)
        for k in['mtproto','vless','vmess']:
            if k in data['sources']and data['sources'][k].startswith('http'):
                config['sources'][k]=data['sources'][k].strip()
        with open(CONFIG_PATH,'w')as f:json.dump(config,f,indent=2)
        return json.dumps({'ok':True,'message':'✅ URL сохранены!'})
    return json.dumps({'ok':False,'error':'Unknown request'})

if __name__=='__main__':
    # Обработка API запросов
    if len(sys.argv)>1 and sys.argv[1]=='--api':
        method=sys.argv[2]if len(sys.argv)>2 else'GET'
        data=sys.argv[3]if len(sys.argv)>3 else None
        if data and data.startswith('{'):
            try:data=json.loads(data)
            except:pass
        print(handle_admin_api(method,data))
        sys.exit(0)
    # Обычный запуск проверки
    signal.signal(signal.SIGINT,lambda s,f:sys.exit(0))
    run_check()
PYEOF
chmod +x "$INSTALL_DIR/proxy_monitor.py"

# ============================================================================
# 5. Admin API (для сохранения и ручного обновления)
# ============================================================================
log_step "Admin API..."
cat > "$INSTALL_DIR/admin_api.py" << 'APIEOF'
#!/usr/bin/env python3
import json,os,sys,subprocess
from http.server import BaseHTTPRequestHandler,HTTPServer
CP='/opt/proxy_monitor/config.json'
SCRIPT='/opt/proxy_monitor/proxy_monitor.py'
VENV='/opt/proxy_monitor/venv/bin/python'
def load():
    with open(CP)as f:return json.load(f)
def save(d):
    c=load()
    if'sources'in d:
        for k in['mtproto','vless','vmess']:
            if k in d['sources']and d['sources'][k].startswith('http'):c['sources'][k]=d['sources'][k].strip()
    with open(CP,'w')as f:json.dump(c,f,indent=2)
    return True
def run_check():
    try:
        subprocess.run([VENV,SCRIPT],timeout=3600,check=True,capture_output=True)
        return True
    except Exception as e:
        return False
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/api/config':
            self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
            self.wfile.write(json.dumps({'ok':True,'config':load()}).encode())
        else:self.send_response(404);self.end_headers()
    def do_POST(self):
        if self.path=='/api/save':
            try:
                l=int(self.headers.get('Content-Length',0));d=json.loads(self.rfile.read(l).decode())
                if'sources'in d and save(d['sources']):
                    self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
                    self.wfile.write(json.dumps({'ok':True,'message':'✅ URL сохранены!'}).encode())
                else:raise Exception('Save failed')
            except Exception as e:
                self.send_response(400);self.send_header('Content-Type','application/json');self.end_headers()
                self.wfile.write(json.dumps({'ok':False,'error':str(e)}).encode())
        elif self.path=='/api/refresh':
            try:
                if run_check():
                    self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
                    self.wfile.write(json.dumps({'ok':True,'message':'✅ Проверка завершена!'}).encode())
                else:raise Exception('Check failed')
            except Exception as e:
                self.send_response(500);self.send_header('Content-Type','application/json');self.end_headers()
                self.wfile.write(json.dumps({'ok':False,'error':str(e)}).encode())
        else:self.send_response(404);self.end_headers()
    def log_message(self,f,*a):pass
if __name__=='__main__':
    p=int(sys.argv[1])if len(sys.argv)>1 else 8081
    print(f"Admin API running on port {p}")
    HTTPServer(('127.0.0.1',p),H).serve_forever()
APIEOF
chmod +x "$INSTALL_DIR/admin_api.py"

# ============================================================================
# 6. admin.html (с кнопкой ручного обновления)
# ============================================================================
log_step "admin.html..."
cat > "$DATA_DIR/admin.html" << 'ADMINEOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport"content="width=device-width"><title>Админ-панель</title><style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:sans-serif;background:linear-gradient(135deg,#667eea,#764ba2);min-height:100vh;padding:20px}.c{max-width:700px;margin:0 auto;background:#fff;border-radius:16px;padding:30px;box-shadow:0 20px 60px rgba(0,0,0,.3)}h1{color:#333;margin-bottom:20px}.nav{display:flex;gap:10px;margin-bottom:25px;flex-wrap:wrap}.nb{padding:10px 20px;background:#667eea;color:#fff;text-decoration:none;border-radius:8px;font-weight:600}.nb.a{background:#11998e}.fg{margin-bottom:20px}.fg label{display:block;margin-bottom:8px;font-weight:600;color:#333}.fg input{width:100%;padding:12px;border:2px solid #e9ecef;border-radius:8px;font-size:1em}.btn{background:linear-gradient(135deg,#11998e,#38ef7d);color:#fff;padding:14px 30px;border:none;border-radius:8px;font-size:1.1em;font-weight:600;cursor:pointer;width:100%;margin-top:10px}.btn-refresh{background:linear-gradient(135deg,#f093fb,#f5576c);margin-top:20px}.btn:disabled{opacity:.6;cursor:not-allowed}.msg{padding:12px;border-radius:8px;margin-bottom:20px;display:none}.msg.s{background:#d4edda;color:#155724}.msg.e{background:#f8d7da;color:#721c24}.status{background:#f8f9fa;padding:15px;border-radius:8px;margin:20px 0;font-size:.9em;color:#666}</style></head><body><div class="c"><h1>⚙️Админ-панель</h1><div class="nav"><a href="/index.html"class="nb">✈️MTProto</a><a href="/vless.html"class="nb">🔷VLESS</a><a href="/vmess.html"class="nb">🔶VMess</a><a href="/admin"class="nb a">⚙️Админ</a></div><div id="msg"class="msg"></div><div class="status" id="status">Загрузка настроек...</div><form id="f"><div class="fg"><label>MTProto URL:</label><input type="url"id="m"required></div><div class="fg"><label>VLESS URL:</label><input type="url"id="v"required></div><div class="fg"><label>VMess URL:</label><input type="url"id="x"required></div><button type="submit"class="btn">💾Сохранить изменения</button></form><button id="refreshBtn"class="btn btn-refresh"onclick="refresh()">🔄 Обновить прокси сейчас</button><p style="margin-top:20px;color:#666;font-size:.9em">💡Авто-проверка: раз в 24 часа | Ручная: кнопка выше</p></div><script>const api='/api';async function load(){try{const r=await fetch(api+'/config',{credentials:'same-origin'}),c=await r.json();if(c.ok){document.getElementById('m').value=c.config.sources.mtproto;document.getElementById('v').value=c.config.sources.vless;document.getElementById('x').value=c.config.sources.vmess;document.getElementById('status').innerHTML='✅ Настройки загружены | Последняя проверка: '+(c.config.last_check||'никогда');}else{show('⚠️Ошибка:'+c.error,'e');}}catch(e){show('⚠️Ошибка сети:'+e.message,'e');}}async function save(e){e.preventDefault();const btn=e.target.querySelector('button[type="submit"]');btn.disabled=true;btn.textContent='Сохранение...';try{const r=await fetch(api+'/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({sources:{mtproto:document.getElementById('m').value.trim(),vless:document.getElementById('v').value.trim(),vmess:document.getElementById('x').value.trim()}})});const d=await r.json();show(d.ok?'✅'+d.message:'❌'+d.error,d.ok?'s':'e');if(d.ok)load();}catch(e){show('❌Ошибка:'+e.message,'e');}finally{btn.disabled=false;btn.textContent='💾Сохранить изменения';}}async function refresh(){const btn=document.getElementById('refreshBtn');btn.disabled=true;btn.textContent='🔄 Проверка...';show('⏳Запуск проверки прокси...','s');try{const r=await fetch(api+'/refresh',{method:'POST'});const d=await r.json();show(d.ok?'✅'+d.message:'❌'+d.error,d.ok?'s':'e');if(d.ok){load();setTimeout(()=>window.location.reload(),2000);}}catch(e){show('❌Ошибка:'+e.message,'e');}finally{btn.disabled=false;btn.textContent='🔄Обновить прокси сейчас';}}function show(t,c){const el=document.getElementById('msg');el.textContent=t;el.className='msg '+c;el.style.display='block';setTimeout(()=>el.style.display='none',5000);}document.getElementById('f').addEventListener('submit',save);window.addEventListener('load',load);</script></body></html>
ADMINEOF
chown "${NGINX_USER}:${NGINX_GROUP}" "$DATA_DIR/admin.html"
chmod 644 "$DATA_DIR/admin.html"

# ============================================================================
# 7. systemd (24 часа интервал)
# ============================================================================
log_step "systemd (24h интервал)..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SVCEOF
[Unit]
Description=Proxy Monitor
After=network.target
[Service]
Type=oneshot
User=$NGINX_USER
Group=$NGINX_GROUP
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/proxy_monitor.py
WorkingDirectory=$INSTALL_DIR
[Install]
WantedBy=multi-user.target
SVCEOF

cat > "/etc/systemd/system/${SERVICE_NAME}.timer" << TMREOF
[Unit]
Description=Run proxy monitor every 24 hours
Requires=${SERVICE_NAME}.service
[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
Unit=${SERVICE_NAME}.service
[Install]
WantedBy=timers.target
TMREOF

cat > "/etc/systemd/system/${API_SERVICE}.service" << APISEOF
[Unit]
Description=Proxy Admin API
After=network.target
[Service]
Type=simple
User=$NGINX_USER
Group=$NGINX_GROUP
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/admin_api.py 8081
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
[Install]
WantedBy=multi-user.target
APISEOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable --now "${SERVICE_NAME}.timer" "${API_SERVICE}.service" 2>/dev/null || true

# ============================================================================
# 8. nginx (с авторизацией и API)
# ============================================================================
log_step "nginx (порт $CUSTOM_PORT)..."

# ✅ Создание .htpasswd (надёжный способ)
HTPASS_FILE="$INSTALL_DIR/.htpasswd"
rm -f "$HTPASS_FILE"

# Пробуем htpasswd, если нет - используем openssl или python
if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nb "$ADMIN_USER" "$ADMIN_PASS" > "$HTPASS_FILE" 2>/dev/null || \
    echo "$(openssl passwd -apr1 "$ADMIN_PASS" 2>/dev/null)" | sed "s/^/${ADMIN_USER}:/" > "$HTPASS_FILE"
else
    # Python fallback
    python3 -c "import crypt,sys;print('${ADMIN_USER}:'+crypt.crypt('${ADMIN_PASS}',crypt.mksalt(crypt.METHOD_SHA512)))" > "$HTPASS_FILE" 2>/dev/null || \
    echo "${ADMIN_USER}:$(openssl passwd -apr1 "$ADMIN_PASS")" > "$HTPASS_FILE"
fi

chown "${NGINX_USER}:${NGINX_GROUP}" "$HTPASS_FILE"
chmod 640 "$HTPASS_FILE"

# Проверка, что файл создан и не пустой
if [ ! -s "$HTPASS_FILE" ]; then
    log_error "Не удалось создать .htpasswd!"
    exit 1
fi

cat > "/etc/nginx/sites-available/proxy-monitor" << NGINXEOF
server {
    listen $CUSTOM_PORT;
    server_name _;
    root $DATA_DIR;
    index index.html index.htm admin.html;

    # ✅ config.json: CORS + локальная сеть
    location = /config.json {
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
        allow 127.0.0.1;
        allow ::1;
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 192.168.0.0/16;
        deny all;
        default_type application/json;
        add_header Cache-Control "no-cache" always;
    }

    # Публичные страницы
    location / {
        try_files \$uri \$uri/ =404;
    }

    # QR коды
    location /qr_codes/ {
        alias $DATA_DIR/qr_codes/;
        expires 7d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # ✅ Админ-панель с авторизацией (ИСПРАВЛЕНО)
    location = /admin {
        auth_basic "Admin Area";
        auth_basic_user_file $INSTALL_DIR/.htpasswd;
        try_files /admin.html =404;
    }

    # ✅ Admin API с авторизацией
    location /api/ {
        auth_basic "Admin Area";
        auth_basic_user_file $INSTALL_DIR/.htpasswd;
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        client_max_body_size 1M;
    }

    # Запрет служебных файлов
    location ~* \.(log|py|mmdb|sh|cgi|json)$ {
        deny all;
        return 403;
    }

    client_max_body_size 10M;
    access_log /var/log/nginx/proxy-monitor-access.log;
    error_log /var/log/nginx/proxy-monitor-error.log warn;
}
NGINXEOF

ln -sf "/etc/nginx/sites-available/proxy-monitor" "/etc/nginx/sites-enabled/proxy-monitor"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t && systemctl reload nginx

# ============================================================================
# 9. Права доступа
# ============================================================================
log_step "Права..."
chown -R "${NGINX_USER}:${NGINX_GROUP}" "$DATA_DIR" "$INSTALL_DIR"
chmod 755 "$DATA_DIR" "$DATA_DIR/qr_codes"
chmod 644 "$DATA_DIR"/*.html 2>/dev/null || true
chmod 644 "$DATA_DIR/qr_codes"/*.png 2>/dev/null || true
chmod 755 "$INSTALL_DIR"/*.py
chmod 640 "$INSTALL_DIR/config.json" "$INSTALL_DIR/.htpasswd"

# ============================================================================
# 10. Первый запуск
# ============================================================================
log_step "Первый запуск..."
sudo -u "$NGINX_USER" "$VENV_DIR/bin/python" "$INSTALL_DIR/proxy_monitor.py" 2>&1 | tail -3 || true

# ============================================================================
# Финал
# ============================================================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   ✅ v9.0 Установка завершена!                            ║${NC}"
echo -e "${GREEN}║   ✅ Пароль в админке • 24ч интервал • Ручное обновление ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}📊 Страницы:${NC}"
echo -e "  ✈️  MTProto: ${YELLOW}http://$DOMAIN:$CUSTOM_PORT/${NC}"
echo -e "  🔷 VLESS:   ${YELLOW}http://$DOMAIN:$CUSTOM_PORT/vless.html${NC}"
echo -e "  🔶 VMess:   ${YELLOW}http://$DOMAIN:$CUSTOM_PORT/vmess.html${NC}"
echo ""
echo -e "${BLUE}🔐 Админ-панель:${NC}"
echo -e "  URL:    ${YELLOW}http://$DOMAIN:$CUSTOM_PORT/admin${NC}"
echo -e "  Логин:  ${YELLOW}$ADMIN_USER${NC}"
echo -e "  Пароль: ${YELLOW}********${NC} (вы задали)"
echo ""
echo -e "${BLUE}⏰ Расписание:${NC}"
echo -e "  Авто-проверка: ${YELLOW}раз в 24 часа${NC}"
echo -e "  Ручная:        ${YELLOW}кнопка в админ-панели${NC}"
echo ""
echo -e "${BLUE}🔧 Управление:${NC}"
echo -e "  Запуск:     ${YELLOW}sudo systemctl start $SERVICE_NAME${NC}"
echo -e "  Статус:     ${YELLOW}systemctl list-timers | grep $SERVICE_NAME${NC}"
echo -e "  Логи:       ${YELLOW}tail -f $DATA_DIR/monitor.log${NC}"
echo ""

# Проверка
echo -e "${YELLOW}═══ Проверка ═══${NC}"
code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$CUSTOM_PORT/)
[ "$code" = "200" ] && echo -e "${GREEN}✅ Веб: 200${NC}" || echo -e "${RED}❌ Веб: $code${NC}"

# Проверка авторизации (без пароля должен быть 401)
code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$CUSTOM_PORT/admin)
[ "$code" = "401" ] && echo -e "${GREEN}✅ Админ: защита паролем (401)${NC}" || echo -e "${YELLOW}⚠️ Админ: $code${NC}"

# Проверка с паролем
code=$(curl -s -u "$ADMIN_USER:$ADMIN_PASS" -o /dev/null -w "%{http_code}" http://localhost:$CUSTOM_PORT/admin)
[ "$code" = "200" ] && echo -e "${GREEN}✅ Админ с паролем: 200${NC}" || echo -e "${RED}❌ Админ с паролем: $code${NC}"

test -f "$DATA_DIR/index.html" && echo -e "${GREEN}✅ index.html${NC}" || echo -e "${RED}❌ index.html${NC}"
qr_count=$(find "$DATA_DIR/qr_codes/" -name "*.png" 2>/dev/null | wc -l)
echo -e "${GREEN}✅ QR кодов: $qr_count${NC}"

echo ""
echo -e "${CYAN}🔗 Откройте: http://$DOMAIN:$CUSTOM_PORT/admin${NC}"
echo -e "${GREEN}🚀 Готово!${NC}"
