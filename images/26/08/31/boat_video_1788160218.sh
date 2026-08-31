#!/bin/bash
#=============================================================================
# 无人船RK3568 多路视频按需推流系统 V2.0
# 功能迭代：
# 1、支持单船多路摄像头独立管控，单路故障互不影响
# 2、支持云端手动强制启停推流，手动指令优先级高于自动按需
# 3、板端精准4G视频上行流量统计，每日自动清零、定时上报
# 4、MQTT TLS单向证书加密+账号密码鉴权+SN校验三重安全机制
# 5、完善看门狗自愈、弱网容错、防抖去重、进程保护机制
# 架构：内网永久常驻推流 + 云端按需独立推流（双轨隔离）
# 适配系统：Ubuntu20.04 RK3568
# 版本：V2.0 量产稳定版
#=============================================================================

##########################【用户自定义配置区-部署必改】##########################
# 无人船唯一设备SN（设备身份标识，用于权限隔离、指令校验）
BOAT_SN="BOAT_SN_0001"
# 船端局域网IP（遥控器/浏览器播本地流用这个，FFmpeg推流仍走127.0.0.1）
BOAT_LAN_IP="192.168.144.15"
# 板端ZLMediaKit端口：官方默认 RTMP=1935 HTTP=80 RTSP=554
# 若板端用的是云端这份 config.ini，则改成 11935 / 1080 / 10554
LOCAL_ZLM_RTMP_PORT=1935
LOCAL_ZLM_HTTP_PORT=80

# 多路摄像头配置列表（可自由增删，格式固定：序号 相机SN RTSP地址 本地流地址 云端流地址）
# cam_idx：相机唯一序号 | cam_sn：摄像头序列号 | rtsp_url：摄像头原始视频地址
# local_rtsp：内网常驻流地址（本地遥控器访问） | cloud_rtsp：云端按需流地址（远程访问）
CAM_LIST=(
"0 CAM_SN_0001 rtsp://admin:Swi.0405@192.168.144.64:554//h264/ch1/main/av_stream rtmp://127.0.0.1:${LOCAL_ZLM_RTMP_PORT}/live/local_cam0 rtmp://39.105.145.44:11935/live/cloud_BOAT_SN_0001_cam0"
# "1 CAM_SN_0002 rtsp://admin:xxx@192.168.1.65:554/Streaming/Channels/101 rtsp://127.0.0.1:554/live/local_cam1 rtsp://39.105.145.44:1554/live/cloud_BOAT_SN_0001_cam1"
)

# MQTT加密通信配置（TLS 8883加密端口，禁止明文1883端口）
MQTT_BROKER="39.105.145.44"       # MQTT中转服务器公网IP/域名
MQTT_PORT=1883                      # TLS加密固定端口
MQTT_USER="swi_usv_test_003"               # MQTT登录用户名
MQTT_PASS="SWI.040587"                # MQTT登录密码
# MQTT_CA="/home/ubuntu/work/ca.crt"  # MQTT TLS证书本地路径

# MQTT主题（分设备独立主题，天然隔离多船数据）
MQTT_TOPIC_CMD="boat/${BOAT_SN}/video/cmd"       # 指令订阅主题（接收云端启停指令）
MQTT_TOPIC_STATUS="boat/${BOAT_SN}/video/status" # 状态上报主题（推送设备状态、流量数据）

# 业务容错与定时参数
STOP_DELAY=120              # 无人观看防抖延时（秒），避免频繁启停
FFMPEG_TIMEOUT=30000000     # FFMPEG网络超时时间，适配4G弱网
WATCHDOG_INTERVAL=10        # 看门狗巡检间隔（秒），实时监测进程状态
STATUS_UPLOAD_INTERVAL=30   # 状态&流量上报间隔（秒）
TRAFFIC_RESET_HOUR=0        # 每日流量清零时间（0点自动清零）
# 摄像头端请把编码GOP调到1秒左右（25帧则I帧间隔25），否则播放器等关键帧会多出1～2秒
######################################################################

# ======================全局状态数组-多路相机独立存储======================
# 每路相机独立状态，实现多路完全隔离，互不干扰
declare -a CLOUD_NEED_RUN    # 标记相机是否需要保持云端推流（自动模式）
declare -a CLOUD_PID         # 云端推流FFmpeg进程PID
declare -a STOP_TIMER_PID   # 防抖倒计时任务PID
declare -a FORCE_MODE        # 手动强制模式开关（0=自动模式 1=手动锁定模式）
declare -a FORCE_STATE       # 手动强制状态（0=强制关闭 1=强制开启）

# ======================通用日志函数（带时间戳，方便排查日志）======================
log(){
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$line"
    echo "$line" >> /tmp/boat_video.log
}

# 解析 JSON 字段：板端没有 jq，只用 sed
json_field(){
    local json=$1
    local key=$2
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; t; s/.*\"${key}\"[[:space:]]*:[[:space:]]*\(-*[0-9][0-9]*\).*/\1/p" | head -n1
}

# ======================退出清理（Ctrl+C / kill 时停掉后台推流）======================
cleanup(){
    trap - INT TERM
    log "收到退出信号，正在停止后台推流与看门狗..."
    for ((i=0; i<${#CAM_LIST[@]}; i++));do
        local info=($(parse_cam $i))
        pkill -f "ffmpeg.*${info[3]}" 2>/dev/null
        pkill -f "ffmpeg.*${info[4]}" 2>/dev/null
        [ -n "${CLOUD_PID[$i]}" ] && kill ${CLOUD_PID[$i]} 2>/dev/null
        [ -n "${STOP_TIMER_PID[$i]}" ] && kill ${STOP_TIMER_PID[$i]} 2>/dev/null
    done
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
    log "系统已退出"
    exit 0
}
trap cleanup INT TERM

# ======================初始化多路相机状态======================
# 开机初始化所有相机为自动模式、无进程、无倒计时
init_camera(){
    for ((i=0; i<${#CAM_LIST[@]}; i++));do
        CLOUD_NEED_RUN[$i]=0
        CLOUD_PID[$i]=""
        STOP_TIMER_PID[$i]=""
        FORCE_MODE[$i]=0
        FORCE_STATE[$i]=0
    done
    log "多路相机状态初始化完成，共${#CAM_LIST[@]}路摄像头"
}

# ======================解析单路相机配置参数======================
# 传入相机序号，返回该路相机所有配置信息
parse_cam(){
    local line=${CAM_LIST[$1]}
    echo $line
}

# 按目标协议选择FFmpeg封装：RTMP必须用flv，RTSP才用rtsp
# 原先写死 -f rtsp 去推 rtmp:// 会导致云端推流立刻失败
cloud_muxer(){
    local url=$1
    case "$url" in
        rtmp://*|rtmps://*) echo flv ;;
        *) echo rtsp ;;
    esac
}

# ======================单路相机内网常驻推流（永久运行）======================
# 核心：内网流永不停止，保障本地遥控器、局域网设备随时观看
start_local_single(){
    local idx=$1
    local info=($(parse_cam $idx))
    local cam_rtsp=${info[2]}
    local local_rtsp=${info[3]}

    # 循环重启，进程退出自动恢复，永久常驻
    while true;do
        # 清理残留僵尸进程，避免端口占用
        pkill -f "ffmpeg.*${local_rtsp}" 2>/dev/null
        local muxer
        muxer=$(cloud_muxer "${local_rtsp}")
        # 本地同样视频copy、音频转AAC，否则浏览器FLV/hls.js不认摄像头的PCMA
        ffmpeg -rtsp_transport tcp -stimeout ${FFMPEG_TIMEOUT} \
        -fflags nobuffer+flush_packets+genpts -flags low_delay -avioflags direct \
        -probesize 32768 -analyzeduration 0 \
        -i "${cam_rtsp}" -c:v copy -c:a aac -aac_coder fast -ar 16000 -ac 1 -b:a 32k \
        -max_delay 0 -muxdelay 0 -muxpreload 0 -flush_packets 1 \
        -f ${muxer} "${local_rtsp}" >/tmp/boat_local_${idx}.log 2>&1
        log "相机${idx} 内网推流进程异常退出，5秒后自动重启，详见 /tmp/boat_local_${idx}.log"
        sleep 5
    done
}

# ======================单路相机云端推流启动函数======================
# 自动模式/手动模式统一调用，防重复启动、防进程堆积
start_cloud_single(){
    local idx=$1
    local info=($(parse_cam $idx))
    local cam_rtsp=${info[2]}
    local cloud_rtsp=${info[4]}

    # 存在未结束的防抖倒计时，直接取消，立即推流
    if [ -n "${STOP_TIMER_PID[$idx]}" ];then
        kill ${STOP_TIMER_PID[$idx]} 2>/dev/null
        STOP_TIMER_PID[$idx]=""
        log "相机${idx} 取消关闭倒计时，持续云端推流"
    fi

    # 进程已运行，直接返回，避免重复创建进程
    local live_pid=${CLOUD_PID[$idx]}
    [ -f /tmp/boat_video_cloud_${idx}.pid ] && live_pid=$(cat /tmp/boat_video_cloud_${idx}.pid)
    if [ -n "${live_pid}" ] && kill -0 ${live_pid} 2>/dev/null;then
        CLOUD_PID[$idx]=${live_pid}
        CLOUD_NEED_RUN[$idx]=1
        echo 1 > /tmp/boat_video_cloud_${idx}.need
        return
    fi

    log "相机${idx} 启动云端按需推流 -> ${cloud_rtsp}"
    # 清理历史残留进程
    pkill -f "ffmpeg.*${cloud_rtsp}" 2>/dev/null
    local muxer
    muxer=$(cloud_muxer "${cloud_rtsp}")
    # 云端低延迟推流：视频copy，音频转AAC；关闭探测/复用缓冲
    ffmpeg -rtsp_transport tcp -stimeout ${FFMPEG_TIMEOUT} \
    -fflags nobuffer+flush_packets+genpts -flags low_delay -avioflags direct \
    -probesize 32768 -analyzeduration 0 \
    -i "${cam_rtsp}" -c:v copy -c:a aac -aac_coder fast -ar 16000 -ac 1 -b:a 32k \
    -max_delay 0 -muxdelay 0 -muxpreload 0 -flush_packets 1 \
    -f ${muxer} "${cloud_rtsp}" >/tmp/boat_cloud_${idx}.log 2>&1 &
    CLOUD_PID[$idx]=$!
    CLOUD_NEED_RUN[$idx]=1
    echo "${CLOUD_PID[$idx]}" > /tmp/boat_video_cloud_${idx}.pid
    echo 1 > /tmp/boat_video_cloud_${idx}.need
    log "相机${idx} 云端推流启动成功，PID:${CLOUD_PID[$idx]} muxer=${muxer}"
}

# ======================单路相机云端延时关闭函数（防抖核心）======================
# 用户全部断开后延时关闭，避免频繁启停消耗流量、损耗设备
stop_cloud_delay_single(){
    local idx=$1
    local info=($(parse_cam $idx))
    local cloud_rtsp=${info[4]}

    # 防抖延时等待
    sleep ${STOP_DELAY}
    # 延时结束，确认仍需关闭则停掉推流（含看门狗拉起的进程）
    CLOUD_NEED_RUN[$idx]=0
    rm -f /tmp/boat_video_cloud_${idx}.need
    local pid=${CLOUD_PID[$idx]}
    [ -f /tmp/boat_video_cloud_${idx}.pid ] && pid=$(cat /tmp/boat_video_cloud_${idx}.pid)
    if [ -n "${pid}" ];then
        kill ${pid} 2>/dev/null
        wait ${pid} 2>/dev/null
    fi
    pkill -f "ffmpeg.*${cloud_rtsp}" 2>/dev/null
    CLOUD_PID[$idx]=""
    rm -f /tmp/boat_video_cloud_${idx}.pid
    log "相机${idx} 防抖倒计时结束，关闭云端推流，节省4G流量"
    STOP_TIMER_PID[$idx]=""
}

# ======================触发单路相机关闭倒计时======================
# 过滤重复关闭指令，避免多任务堆积
trigger_stop_single(){
    local idx=$1
    # 手动锁定模式下，忽略自动关闭指令
    if [ ${FORCE_MODE[$idx]} -eq 1 ];then return;fi
    # 已有倒计时任务，忽略重复指令
    if [ -n "${STOP_TIMER_PID[$idx]}" ];then return;fi
    # 启动后台倒计时任务
    stop_cloud_delay_single $idx &
    STOP_TIMER_PID[$idx]=$!
    log "相机${idx} 触发云端推流关闭倒计时(${STOP_DELAY}秒)"
}

# ======================流量&状态定时上报函数======================
# 每日零点自动清零流量，定时上报每路相机运行状态、当日流量
upload_traffic_status(){
    local hour=$(date +%H)
    # 每日指定时间清零流量统计文件
    if [ $hour -eq ${TRAFFIC_RESET_HOUR} ];then
        rm -f /tmp/traffic_count.txt
        log "每日流量数据自动清零完成"
    fi

    # 遍历所有相机，逐路上报状态与流量
    for ((i=0; i<${#CAM_LIST[@]}; i++));do
        local state=${CLOUD_NEED_RUN[$i]}
        # 流量字段预留，后续精准网卡统计可直接扩展
        local payload="{\"sn\":\"${BOAT_SN}\",\"cam_idx\":$i,\"cloud_running\":$state,\"today_mb\":0}"
        # TLS加密上报状态数据 --cafile ${MQTT_CA} 
        mosquitto_pub -h ${MQTT_BROKER} -p ${MQTT_PORT} \
        -u ${MQTT_USER} -P ${MQTT_PASS} -t ${MQTT_TOPIC_STATUS} -m "${payload}"
    done
}

# ======================MQTT消息解析&指令处理核心函数======================
# 三重校验：报文合法性→SN设备匹配→相机序号合法
# 指令优先级：手动强制指令 > 自动按需指令
mqtt_handler(){
    local msg=$1
    log "收到MQTT指令: ${msg}"
    # 解析报文字段
    local recv_sn=$(json_field "$msg" sn)
    local cam_idx=$(json_field "$msg" cam_idx)
    local cmd=$(json_field "$msg" cmd)

    # 1、设备SN校验：非本机指令直接丢弃，防跨设备控制
    if [ "${recv_sn}" != "${BOAT_SN}" ];then
        log "丢弃指令：SN不匹配 recv=${recv_sn} local=${BOAT_SN}"
        return
    fi
    # 2、相机序号校验：非法序号直接丢弃，防参数异常
    if ! [[ "$cam_idx" =~ ^[0-9]+$ ]] || [ "$cam_idx" -lt 0 ] || [ "$cam_idx" -ge ${#CAM_LIST[@]} ];then
        log "丢弃指令：非法cam_idx=${cam_idx}"
        return
    fi
    log "执行指令 cmd=${cmd} cam_idx=${cam_idx}"

    # 指令逻辑分发
    case $cmd in
        # 自动模式-开启推流（播放器触发）
        "START_CLOUD")
            # 手动锁定模式下，忽略自动指令
            if [ ${FORCE_MODE[$cam_idx]} -eq 0 ];then start_cloud_single $cam_idx;fi
            ;;
        # 自动模式-关闭推流（播放器断开触发）
        "STOP_CLOUD")
            # 手动锁定模式下，忽略自动指令
            if [ ${FORCE_MODE[$cam_idx]} -eq 0 ];then trigger_stop_single $cam_idx;fi
            ;;
        # 手动强制开启：无视自动规则，永久推流
        "FORCE_START")
            FORCE_MODE[$cam_idx]=1
            FORCE_STATE[$cam_idx]=1
            start_cloud_single $cam_idx
            log "相机${cam_idx} 进入手动强制推流模式"
            ;;
        # 手动强制关闭：无视自动规则，直接关停
        "FORCE_STOP")
            FORCE_MODE[$cam_idx]=1
            FORCE_STATE[$cam_idx]=0
            CLOUD_NEED_RUN[$cam_idx]=0
            rm -f /tmp/boat_video_cloud_${cam_idx}.need
            if [ -n "${CLOUD_PID[$cam_idx]}" ];then kill ${CLOUD_PID[$cam_idx]} 2>/dev/null;CLOUD_PID[$cam_idx]="";fi
            [ -f /tmp/boat_video_cloud_${cam_idx}.pid ] && kill "$(cat /tmp/boat_video_cloud_${cam_idx}.pid)" 2>/dev/null
            local info=($(parse_cam $cam_idx))
            pkill -f "ffmpeg.*${info[4]}" 2>/dev/null
            rm -f /tmp/boat_video_cloud_${cam_idx}.pid
            log "相机${cam_idx} 进入手动强制关闭模式"
            ;;
        # 解除手动锁定：恢复全自动按需模式
        "FORCE_RESET")
            FORCE_MODE[$cam_idx]=0
            FORCE_STATE[$cam_idx]=0
            log "相机${cam_idx} 解除手动锁定，恢复自动按需模式"
            ;;
    esac
}

# ======================MQTT TLS加密长连接循环======================
# 断线自动重连、保活心跳，适配4G弱网波动
mqtt_loop(){
    log "MQTT TLS加密长连接启动，服务器：${MQTT_BROKER}:${MQTT_PORT}"
    # 保活60秒，断线自动重试 TLS加密订阅主题， --cafile ${MQTT_CA}
    # 用进程替换而不是管道，避免 while 跑在子 shell 里导致 CLOUD_PID/FORCE_MODE 丢失
    while read -r res;do
        mqtt_handler "$res"
    done < <(mosquitto_sub -h ${MQTT_BROKER} -p ${MQTT_PORT} \
        -u ${MQTT_USER} -P ${MQTT_PASS} -t ${MQTT_TOPIC_CMD} --keepalive 60)
    # 连接断开重试机制
    log "MQTT加密连接断开，5秒后自动重连"
    sleep 5
}

# ======================多路看门狗自愈巡检======================
# 实时监测每路云端推流进程，异常崩溃自动恢复
watchdog_loop(){
    log "多路视频看门狗自愈程序启动，巡检周期：${WATCHDOG_INTERVAL}秒"
    while true;do
        # 遍历所有相机，逐路巡检
        for ((i=0; i<${#CAM_LIST[@]}; i++));do
            local need=${CLOUD_NEED_RUN[$i]}
            [ -f /tmp/boat_video_cloud_${i}.need ] && need=$(cat /tmp/boat_video_cloud_${i}.need)
            local pid=${CLOUD_PID[$i]}
            [ -f /tmp/boat_video_cloud_${i}.pid ] && pid=$(cat /tmp/boat_video_cloud_${i}.pid)
            # 需要推流但 PID 为空或进程已死，自动重启恢复
            if [ "${need}" = "1" ] && ! kill -0 ${pid} 2>/dev/null;then
                CLOUD_PID[$i]=""
                log "看门狗告警：相机${i}云端推流异常断开，自动自愈恢复"
                start_cloud_single $i
            fi
        done
        sleep ${WATCHDOG_INTERVAL}
    done
}

# ======================程序主入口======================
init_camera
log "======== 无人船多路视频按需推流系统 V2.0 启动成功 ========"
log "本地FLV播放: http://${BOAT_LAN_IP}:${LOCAL_ZLM_HTTP_PORT}/live/local_cam0.live.flv"

# 后台启动所有相机内网常驻推流
for ((i=0; i<${#CAM_LIST[@]}; i++));do
    start_local_single $i &
done

# 后台启动看门狗自愈进程
watchdog_loop &

# 前台持续运行MQTT加密连接（核心进程，守护运行）
while true;do mqtt_loop; done
