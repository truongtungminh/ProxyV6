#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c12
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    # Ghép chuỗi với $IP6 (là phần sub của IPv6 lấy từ icanhazip.com)
    echo "$IP6:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "installing 3proxy"
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
}

gen_data() {
    userproxy=user
    passproxy=pass
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "$userproxy/$passproxy/$IP4/$port/$(gen64)"
    done
}

gen_iptables() {
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

echo "installing apps"
yum -y install wget gcc net-tools bsdtar zip >/dev/null

cat << EOF > /etc/rc.d/rc.local
#!/bin/bash
touch /var/lock/subsys/local
EOF

echo "installing apps"
yum -y install wget gcc net-tools bsdtar zip >/dev/null

install_3proxy

echo "working folder = /home/cloudfly"
WORKDIR="/home/cloudfly"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

IP4=$(curl -4 -s icanhazip.com)
# Lấy phần đầu của IPv6 làm sub (ví dụ: 2407:5b40:0:240)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal ip = ${IP4}. External sub for ip6 = ${IP6}"

while :; do
  read -p "Enter FIRST_PORT between 21000 and 61000: " FIRST_PORT
  [[ $FIRST_PORT =~ ^[0-9]+$ ]] || { echo "Enter a valid number"; continue; }
  if ((FIRST_PORT >= 21000 && FIRST_PORT <= 61000)); then
    echo "OK! Valid number"
    break
  else
    echo "Number out of range, try again"
  fi
done
LAST_PORT=$(($FIRST_PORT + 1000))
echo "LAST_PORT is $LAST_PORT. Continue..."

gen_data >$WORKDIR/data.txt
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x ${WORKDIR}/boot_*.sh /etc/rc.d/rc.local

gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >>/etc/rc.d/rc.local <<EOF
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 1000048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
chmod 0755 /etc/rc.d/rc.local
bash /etc/rc.d/rc.local

gen_proxy_file_for_user

echo "Starting Proxy"
download_proxy

#############################
# Phần bổ sung xoay proxy V6 mỗi 5 phút
#############################
# Tạo file cấu hình chứa các biến cần thiết cho rotate
cat <<EOF > ${WORKDIR}/proxy_config.env
export FIRST_PORT=${FIRST_PORT}
export LAST_PORT=${LAST_PORT}
export IP4=${IP4}
export IP6=${IP6}
EOF

# Tạo script rotate_proxy.sh để cập nhật proxy IPv6
cat << 'EOF' > ${WORKDIR}/rotate_proxy.sh
#!/bin/sh
WORKDIR="/home/cloudfly"
# Nạp các biến cấu hình
if [ -f ${WORKDIR}/proxy_config.env ]; then
  . ${WORKDIR}/proxy_config.env
fi

# Định nghĩa lại hàm gen64 cho rotate (sử dụng IP6 đã được export)
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$IP6:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Hàm gen_data dùng để tạo dữ liệu proxy mới
gen_data() {
    userproxy=user
    passproxy=pass
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "$userproxy/$passproxy/$IP4/$port/$(gen64)"
    done
}

# Hàm gen_ifconfig: tạo lệnh thêm địa chỉ IPv6
gen_ifconfig() {
    awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDIR}/data.txt
}

# Hàm gen_3proxy: tạo file cấu hình cho 3proxy
gen_3proxy() {
    echo "daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver:2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush
auth strong
users user:CL:pass
" 
    awk -F "/" '{print "auth strong\nallow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush"}' ${WORKDIR}/data.txt
}

# Tạo lại file dữ liệu proxy mới
gen_data > ${WORKDIR}/data.txt
# Cập nhật lại cấu hình IPv6 trên giao diện: xóa các địa chỉ cũ và thêm mới
ip -6 addr flush dev eth0
gen_ifconfig > ${WORKDIR}/boot_ifconfig.sh
bash ${WORKDIR}/boot_ifconfig.sh
# Tạo lại file cấu hình 3proxy
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg
# Khởi động lại 3proxy
pkill 3proxy
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

chmod +x ${WORKDIR}/rotate_proxy.sh

# Thêm cron job để chạy rotate_proxy.sh mỗi 5 phút
(crontab -l 2>/dev/null; echo "*/5 * * * * bash ${WORKDIR}/rotate_proxy.sh") | crontab -

echo "Cron job for rotating proxy every 5 minutes has been installed."
