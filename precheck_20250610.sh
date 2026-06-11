#!/bin/bash
#author: feilunshuai
#version: v1.5
#在数据库安装的用户下执行，如vastbase
#用户需要有sudo权限,如果需要做fio测试的话
# dependencies: 要配置好yum或者apt-get源或手动安装
# 配置好自定义参数部分，如果要检查主机间网络带宽，需要配置好远程iperf3服务(iperf3 -s -p 5201)
# usage:
	# sh precheck.sh    （硬件检查部分只执行fio压测）
	# sh precheck.sh 192.168.0.134  （硬件检查部分 执行fio和iperf3压测）
	# sh precheck.sh nofio
source ~/.bashrc
set -e 
if [[ -z $PGDATA ]];then
	echo "Error: PGDATA is null."
	exit 1 
fi

#test connection
v_ds=$(gsql -r -d postgres -t -A -c "select count(*) from pg_database;")
if [[ -z $v_ds ]];then
	echo "Error: can not connect to db."
	exit 1
fi
##===自定义参数,只对fio测试，如果不做fio测试可以忽略
#数据压测盘
DATA_DISK=$PGDATA/tmp_0792
if [[ ! -d $DATA_DISK ]];then
	mkdir -p $DATA_DISK
fi

#网络对比带宽，需要保证本机和remote_ip之间启动了iperf3服务，否则iperf3执行失败，iperf3的默认开启端口是5201
remote_ip="$1"
remote_port=5201

#fio读写操作的数据块大小
fio_bs='8k'
#fio测试的文件的总大小
fio_size='1G'
#fio并行大小
fio_numjobs=100
#fio跑300s
fio_rumtime=300
#混合读写，读占比70%
fio_rwmixread=70

##########end ####

sql_mode_name=$(gsql -r -d postgres -t -A -c "select name from pg_settings where name like '%_sql_mode'")
exlude_keywords=$(gsql -r -d postgres -t -A -c "select name from pg_settings where name like '%_exclude_reserved_words'")

v_s=$(gsql -r -d postgres -t -A -c "select count(*) from pg_stat_replication;")
v_transreadonly=$(gsql -r -d postgres -t -A -c "show transaction_read_only;")
if [[ $v_s -gt 0 ]];then
	data_node=$(cat $PGDATA/postgresql.conf|grep ^replconninfo |egrep -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" |sort -n |uniq)
else
	data_node=$(ifconfig -a |egrep '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |grep -v '127.0.0.1' |awk '{print $2}' |sort -n |uniq)
fi


v_time=$(date +%Y%m%d_%H%M%S)
#echo $v_time
file_name="precheck_$(hostname)_${v_time}.html"
#file_name='test.html'

memtotal=$(cat /proc/meminfo |grep MemTotal |awk '{print $2}')
mem43=$(echo $memtotal*0.75 |bc)
mem41=$(echo $memtotal*0.25 |bc)
# 定义查询列表
declare -A params
params=(
  [shared_buffers]=${mem41}
  [effective_cache_size]=${mem43}
  [max_process_memory]=${mem43}
  [maintenance_work_mem]=512MB
  [work_mem]=4MB
  [synchronous_commit]=on
  [listen_addresses]="*|0.0.0.0"
  [fsync]=on
  [full_page_writes]=off
  [enable_double_write]=on
  [enable_wdr_snapshot]=on
  [enable_resource_track]=on
  [enable_cbm_tracking]=on
  [enable_memory_limit]=on
  [wal_log_hints]=on
  [enable_stmt_track]=on
  [temp_file_limit]="50GB|no_-1"
  [synchronous_standby_names]="*"
  [checkpoint_timeout]=15min
  [wal_level]=hot_standby
  [logging_collector]=on
  [log_rotation_age]=1d
  [wal_keep_segments]=128
  [checkpoint_completion_target]=0.9
  [archive_mode]=on
  [max_connections]="1000|no_require"
  [log_duration]=on
  [log_statement]=ddl
  [log_lock_waits]=on
  [track_functions]=none
  [password_force_alter]=off
  [password_effect_time]=36500
  [$exlude_keywords]="no_require"
  [session_timeout]="30min|>0"
  [sql_compatibility]="no_require"
  [$sql_mode_name]="no_require"
)

# 创建 HTML 头部
cat <<EOF > $file_name
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>上线前检查</title>
<style>
  table { width: 100%; border-collapse: collapse; margin: 20px auto; }
  th, td { padding: 10px; border: 1px solid #ccc; text-align: center; }
  th { background-color: #f2f2f2; }
  .correct { background-color: #d4edda; color: #155724; }
  .incorrect { background-color: #fff3cd; color: #856404; }
    </style>
</head>
<body>
<h1>上线前检查</h1>
<h2 style="text-align:center;">参数检查结果</h2>
<table>
<tr>
<th>参数名</th>
<th>实际值</th>
<th>推荐值</th>
<th>是否符合上线标准</th>
<th>查询sql</th>
<th>调整语句</th>
</tr>
EOF

# 遍历参数并获取实际值
for param in "${!params[@]}"; do
  actual_value=$(gsql -r -t -A -c  "show $param" 2>/dev/null)
  if [[ $param == 'shared_buffers' || $param == 'effective_cache_size' || $param == 'max_process_memory' ]];then 
  	if [[ "$actual_value" =~ GB$ ]];then
  	      recommended_value=$(echo ${params[$param]}/1024/1024 |bc)GB
  	elif [[ "$actual_value" =~ MB$ ]];then
  	      recommended_value=$(echo ${params[$param]}/1024 |bc)MB
  	elif [[ "$actual_value" =~ KB$ ]];then
  	      recommended_value=${params[$param]}KB
  	else
  	      recommended_value=${params[$param]}
  	fi
  else
	recommended_value=${params[$param]}
  fi

  IFS='|' read -ra rec_values <<< "$recommended_value"
  result="<td class='incorrect'>否</td>"
  modify_statment="gs_guc reload -N all -I all -c \"$param=${rec_values[0]}\""
  for rec_value in "${rec_values[@]}"; do
    if [[ "$rec_value" =~ ">" ]];then
	    rec_value=${rec_value#*>}
	    #actual_value=$(echo $actual_value|egrep -o '[0-9]+')
	    if [[ "$actual_value" > "$rec_value" ]];then
		    result="<td class='correct'>是</td>"
		    modify_statment=""
		    break
	    fi
    elif [[ "$rec_value" =~ "<" ]];then
	    rec_value=${rec_value#*<}
	    #actual_value=$(echo $actual_value|egrep -o '[0-9]+')
	    if [[ "$actual_value" < "$rec_value" ]];then
                    result="<td class='correct'>是</td>"
                    modify_statment=""
                    break
            fi
    elif [[ "$actual_value" == "$rec_value" || ("$param" == 'listen_addresses' && "$actual_value" =~ "$rec_value") || ("$rec_value" == 'no_-1' && "$actual_value" != '-1') || "$rec_value" == 'no_require' ]]; then
      result="<td class='correct'>是</td>"
      modify_statment=""
      break
    fi
  done

  query_sql="show $param;"
  echo "<tr><td>$param</td><td style='max-width: 200px; overflow-wrap: break-word;'>$actual_value</td><td>$recommended_value</td>$result<td>$query_sql</td><td>$modify_statment</td></tr>" >> $file_name 
done

cat <<EOF >> $file_name
</table>
</r>
</r>
EOF


#########system check part2
cat <<EOF >> $file_name
<h2 style="text-align:center;">系统参数检查结果</h2>
<table>
<tr>
<th>检查项</th>
<th>实际值</th>
<th>推荐值</th>
<th>结果</th>
<th>检查命令</th>
</tr>
EOF

check_command() {
  local item=$1
  local cmd=$2
  local recommended=$3
  local result="<td class='incorrect'>不一致</td>"

  actual_value=$(eval "$cmd" | tr -d '\n')
  IFS='|' read -ra rec_values <<< "$recommended"
  for rec_value in "${rec_values[@]}"; do
    if [[ "$rec_value" =~ "<" ]]; then
	    threshold=${rec_value:1:-1}
	    #echo $threshold
	    if [[ "$actual_value" =~ ^[0-9]+(\.[0-9]+)?[%|MB|GB]?$ ]]; then
		    value=$(echo "$actual_value" | tr -d '%'|tr -d 'MB' |tr -d 'GB')
		    #echo $value
		    if (( $(echo "$value < $threshold" | bc -l) )); then
			    result="<td class='correct'>正常</td>"
			    break
		    fi
 	    fi
    elif [[ "$rec_value" =~ ">" ]]; then
	    threshold=${rec_value:1:-1}
	    #echo $threshold
	    if [[ "$actual_value" =~ ^[0-9]+(\.[0-9]+)?[%|MB|GB]?$ ]]; then
		    value=$(echo "$actual_value" | tr -d '%'|tr -d 'MB' |tr -d 'GB')
		    #echo $value
		    if (( $(echo "$value > $threshold" | bc -l) )); then
			    result="<td class='correct'>正常</td>"
			    break
		    fi
 	    fi
    elif [[ "$actual_value" == *"$rec_value"* || "$rec_value" == 'no_require' ]]; then
      result="<td class='correct'>正常</td>"
      break
    fi
  done
  #v_cmd=$(echo $cmd |awk -F'!' '{print $1}')
  echo "<tr><td style='max-width: 200px; overflow-wrap: break-word;'>$item</td><td style='max-width: 200px; overflow-wrap: break-word;'>$actual_value</td><td style='max-width: 200px; overflow-wrap: break-word;'>$recommended</td>$result<td style='max-width: 300px; overflow-wrap: break-word;'>$cmd</td></tr>" >> $file_name 
}

# 执行检查
check_command "CPU使用率" "top -bn1 | grep '%Cpu' | awk '{print \$2\"%\"}'" "<70%"
check_command "内存使用率" "free -m | awk '/Mem:/ {printf(\"%.1f%%\", \$3/\$2*100)}'" "<80%"
check_command "磁盘空间使用" "df -h --output=pcent \$(df -h $PGDATA|tail -n1| awk '{print \$NF}')|tail -n1|tr -d ' '" "<70%"
check_command "时间同步检查" "timedatectl status |grep 'System clock synchronized' |awk -F':' '{print \$2}'|tr -d ' '" "yes"
check_command "语言配置" "echo \$LANG" "en_US.UTF-8"
check_command "防火墙" "v_a=\$(systemctl is-active  firewalld);if [[ \$v_a == 'active' ]] ;then sudo firewall-cmd --list-port |egrep -o '5432|5433|5436|5437|15000|15001|15002'  |sort |uniq -u |paste -s -d','  ; else echo 'inactive'  ; fi" "inactive|5432,5433,5436,5437,15000,15001,15002"
check_command "selinux" "getenforce" "0|Disabled"
check_command "IPC" "grep ^RemoveIPC=no /etc/systemd/logind.conf" "RemoveIPC=no"
check_command "自动定时任务及脚本检查root" "sudo crontab -l -u root 2>/dev/null|egrep -o 'nmon_sh.sh|oswatch|database_fullbackup.sh|database_increbackup.sh|cleanarch.sh'" "nmon_sh.sh|oswatch|database_fullbackup.sh|database_increbackup.sh|cleanarch.sh|no_require"
check_command "自动定时任务及脚本检查$USER" "crontab -l  2>/dev/null|egrep -o 'nmon_sh.sh|oswatch|database_fullbackup.sh|database_increbackup.sh|cleanarch.sh'" "nmon_sh.sh|oswatch|database_fullbackup.sh|database_increbackup.sh|cleanarch.sh|no_require"
check_command "定时任务for_$USER" "crontab -l 2>/dev/null|grep -v '^#'|grep -v '^$'|sed 's/$/\\\n/g'|egrep -v 'CheckSshAgent|om_monitor'" "no_require"
check_command "监控工具检查" "ps -eo cmd| egrep 'nmon|VEM|oswatch' | grep -v grep" "nmon|VEM|oswatch"
check_command "huge_pages" "grep HugePages_Total /proc/meminfo | awk '{print \$2}'" "0|no_require"
check_command "transparent_hugepage" "cat /sys/kernel/mm/transparent_hugepage/enabled" "never"
check_command "无Vpatch相关环境变量" "sudo cat /root/.bashrc |grep -i vpatch|grep -v '^#' |wc -l" "0"
check_command "数据库-服务是否正常运行" "gs_ctl  query |grep db_state |awk -F':' '{print \$2}'|tr -d ' '" "Normal" 
if [[ $v_s -gt 0 ]];then
	check_command "数据库-主备延迟" "gsql -r -t -A -c 'select pg_xlog_location_diff(A.c1,receiver_replay_location)/(1024 * 1024) AS slave_latency_MB from pg_stat_replication,pg_current_xlog_location() AS A(c1);'" "<20MB"
	check_command "数据库-复制槽" "gsql -r -t -A -c 'select count(*) from pg_replication_slots;'" ">0 "
fi
if [[ $v_s -eq 0 && $v_transreadonly == 'off' ]];then
	check_command "单机vastbase服务检查" "systemctl is-active vastbase" "active"
elif [[ $v_s -gt 0 && $v_transreadonly == 'off' ]];then
        if command -v gs_om >/dev/null 2>&1; then
		check_command "集群状态检查" "gs_om -t status --detail |sed  -n '/Datanode State/,\$p' |sed  -n '/----/,\$p'| sed '1d' |grep -v 'Normal' |wc -l" "0"
	fi
fi
check_command "数据库-长事务>30min" "gsql -r -t -A -c \"select count(*) from pg_stat_activity where  state<>'idle' and query <> 'WLM fetch collect info from data nodes' and  xact_start < now() - interval '30 min';\"" "0"
check_command "数据库-缓存命中率" "gsql -r -t -A -c \"select round(min(cache_hit_ratio),2)||'%' from (select datname,blks_hit::float/(blks_read+blks_hit)*100  as cache_hit_ratio from pg_stat_database where  blks_read+blks_hit !=0 and datname in(select datname from pg_database where datname<>'template1' and datname<>'template0'));\"" ">95%"
check_command "数据库-连接数" "gsql -r -t -A -c \"select to_char(count(*)*100/(select setting from pg_settings where name='max_connections'),'0.99') ||'%' use_pct  from pg_stat_activity;\"|tr -d ' '" "<80%"
check_command "数据库-客户端认证策略" "cat $PGDATA/pg_hba.conf |egrep -v '^#|^$'  |wc -l" ">0 "
for v_db in $(gsql -r -A -t -c "SELECT datname FROM pg_database WHERE datistemplate = false and datname not in('vastbase','panweidb');")
do
	check_command "$v_db库上插件" "gsql -r -t -A -d $v_db -c \"select extname from pg_extension WHERE extname = 'pg_stat_statements'\"" "pg_stat_statements|no_require"
	check_command "$v_db库-统计信息更新" "gsql -r -t -A -d $v_db -c 'select count(*) from pg_stat_user_tables where last_analyze is null and last_autoanalyze is null;'" "0"
	check_command "$v_db-表和索引数量是否合理" "gsql -r -t -A -d $v_db -c \"with pg_tab as (select count(tablename) tbl_num from pg_tables where schemaname<>'pg_catalog' and schemaname<>'information_schema'),pg_idx as (select count(indexname) index_num from pg_indexes where schemaname<>'pg_catalog') select round(index_num/tbl_num,2) idx_tab from pg_tab,pg_idx;\"" ">1.5 |no_require"
	v_sql="with 
tbl_des as (SELECT 
pg_catalog.obj_description(c.oid, 'pg_class') as description
FROM pg_catalog.pg_class c
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p','')
AND n.nspname <> 'pg_catalog'
AND n.nspname <> 'information_schema'
AND n.nspname !~ '^pg_toast'
AND c.relname in (select tablename from pg_tables where schemaname<>'pg_catalog' and schemaname<>'information_schema')),
des_num as (select count(description) description_num from tbl_des where description is not null),
tbl_num as (select count(*) tbl_total_num from pg_tables where schemaname<>'pg_catalog' and schemaname<>'information_schema')
select round(description_num/tbl_total_num,2)*100||'%' tbl_des_per from tbl_num,des_num;"
	check_command "$v_db-表和列注释情况" "gsql -r -t -A -d $v_db -c \"$v_sql\"" ">85%"
	check_command "$v_db-是否存在保留关键字作为对象名" "gsql -r -t -A -d $v_db -c \"select count(b.attrelid::regclass||','||b.attname) from pg_get_keywords() a ,pg_attribute b ,pg_class c where  a.word=b.attname and  b.attrelid=c.oid  and catcode ='R' and b.attnum>0 and c.relowner>99\"" "0"
done
v_logdir=$(gsql -r -A -t -c "show log_directory;")
check_command "数据库-运行日志是否异常" "grep -E 'WARNING|ERROR|FATAL' $v_logdir/*.log |wc -l" "0"
v_license_path=$(gsql -r -t -A -c "select setting from  pg_settings where name in('license_path') ;")
if [[ "$sql_mode_name" == 'panweidb_sql_mode' ]];then
	licensetool="pw_licensetool"
	v_dbtype=panweidb
	v_varenv_path=~/.Panwei
else
	licensetool="vb_licensetool"
	v_dbtype=vastbase
	v_varenv_path=~/.Vastbase
fi
v_permanent=$(date -d "2969-01-01" +%s)
check_command "数据库-许可的有效期确认" "$licensetool --dump=$v_license_path|egrep -o 'Expires On:[^,]*,'| egrep -o \"'.*'\"|sed \"s/'//g\"|xargs -i date -d {} +%s" ">$v_permanent "
check_command "数据库-进程最大允许打开文件数" "ulimit  -n"  ">102399 |unlimited"
check_command "数据库-$v_varenv_path文件检查" "ls $v_varenv_path" "$v_varenv_path"
check_command "数据库-是否已创建必须函数" "gsql -r -A -t -c \"select string_agg(distinct proname, ',' ORDER BY proname) AS result from pg_proc where proname in ('isnull','if','datediff','date_diff','period_diff','truncate','right_str');\"" "datediff,if,isnull,period_diff,right_str,truncate|no_require"



cat <<EOF >> $file_name
</table>
</r>
</r>
EOF

########hardware check part3
cat <<EOF >> $file_name
<h2 style="text-align:center;">DISK检查结果</h2>
<table>
<tr>
<th>测试项</th>
<th>读带宽</th>
<th>写带宽</th>
<th>读IOPS</th>
<th>写IOPS</th>
<th>磁盘使用率</th>
</tr>
EOF





##===默认参数
html_file=$file_name
# 设置红色文本
RED='\033[0;31m'
# 设置绿色文本
GREEN='\033[0;32m'
# 设置黄色
YELLOW='\033[93m'
# 重置文本颜色
NC='\033[0m'

check_os(){
	# 检查操作系统环境
	if [[ "$(uname)" == "Linux" ]]; then
	    if [[ -n "$(command -v yum)" ]]; then
	        PACKAGE_MANAGER="yum"
	    elif [[ -n "$(command -v apt-get)" ]]; then
	        PACKAGE_MANAGER="apt-get"
	    else
	        echo -e "${RED}无法确定软件包管理工具，请手动安装fio和perf${NC}"
	        exit 1
	    fi
	else
	    echo -e "${RED}脚本仅支持Linux操作系统${NC}"
	    exit 1
	fi
}
check_fio(){
	# 检查是否已安装fio
	if ! command -v fio &> /dev/null; then
	    echo -e "${RED}fio 未安装，开始安装...${NC}"
	    if [[ "$PACKAGE_MANAGER" == "yum" ]]; then
	        if sudo yum install -y fio; then
	            echo -e "${GREEN}fio 安装成功${NC}"
	        else
	            echo -e "${RED}fio 安装失败${NC}"
	            exit 1
	        fi
	    elif [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
	        if sudo apt-get install -y fio; then
	            echo -e "${GREEN}fio 安装成功${NC}"
	        else
	            echo -e "${RED}fio 安装失败${NC}"
	            exit 1
	        fi
	    fi
	fi
	echo -e "${GREEN}fio 磁盘压测工具已安装${NC}"
}
check_iperf3(){
	# 检查是否已安装perf
	if ! command -v iperf3 &> /dev/null; then
	    echo -e "${RED}iperf3 未安装，开始安装...${NC}"
	    if [[ "$PACKAGE_MANAGER" == "yum" ]]; then
	        if sudo yum install -y iperf3; then
	            echo -e "${GREEN}iperf3 安装成功${NC}"
	        else
	            echo -e "${RED}iperf3 安装失败${NC}"
	            exit 1
	        fi
	    elif [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
	        if sudo apt-get install -y iperf3; then
	            echo -e "${GREEN}iperf3 安装成功${NC}"
	        else
	            echo -e "${RED}iperf3 安装失败${NC}"
	            exit 1
	        fi
	    fi
	fi
	echo -e "${GREEN}iperf3 网络检测工具已安装${NC}"
}
#跑fio命令
run_fio() {
    local bs="$1"
    local size="$2"
    local numjobs="$3"
    local runtime="$4"
    local rw="$5"
    local output="$6"
    local rwmixread="$7"

    local fio_command="fio --direct=1 --iodepth=10 --bs=${bs} --size=${size} --numjobs=${numjobs} --runtime=${runtime} --group_reporting --rw=${rw} --name=test --filename=${DATA_DISK}/randrw.file --output=/tmp/${output}.txt"
	echo "执行命令: $fio_command"

    if [ -n "$rwmixread" ]; then
        fio_command+=" --rwmixread=${rwmixread}"
    fi

    rm -rf "/tmp/fio_${output}.txt"
    echo "Running fio command: $fio_command"

    $fio_command

    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "${YELLOW}fio command execution failed with exit code $exit_code ${NC}"
        exit
    fi
}
## 解析fio结果
# 正则表达式模式
bw_pattern="bw=([0-9.]+)([A-Z]*)"
iops_pattern="IOPS=([0-9.]+)"
util_pattern="util=([0-9.]+)%"

read_iops=''
read_bw=''
write_iops=''
write_bw=''
disk_util=''
bw=''
iops=''

#解析fio非混合读写结果
extract_info_single() {
    local result_file="$1"
    local fio_type="$2"
    local bw_unit=""

    if [[ -f "$result_file" ]]; then
        # 提取带宽
        if [[ $(grep -oPi "$bw_pattern" "$result_file") =~ $bw_pattern ]]; then
            bw="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
            bw_unit="${BASH_REMATCH[2]}"
        fi

        # 提取IOPS
        if [[ $(grep -E -oi "$iops_pattern" "$result_file") =~ $iops_pattern ]]; then
            iops="${BASH_REMATCH[1]}"
        fi

        # 提取磁盘使用率
        if [[ $(grep -E -oi "$util_pattern" "$result_file") =~ $util_pattern ]]; then
            disk_util="${BASH_REMATCH[1]}"
        fi

    else
        echo "no file $1"
    fi

    #echo "$2 带宽: $bw$bw_unit"
   # echo "IOPS: $iops"
    #echo "磁盘使用率: $disk_util%"

}

#解析fio混合读写结果
extract_info_mix() {
    local result_file="$1"

    if [[ -f "$result_file" ]]; then
        
        # 提取读带宽
        read_bw=$(grep 'read:' "$result_file" |grep -oPi 'BW=([0-9.]+)([A-Z]*)'|awk -F "=" '{print $2}')

        # 提取写带宽
        write_bw=$(grep 'write:' "$result_file" |grep -oPi 'BW=([0-9.]+)([A-Z]*)'|awk -F "=" '{print $2}')


        # 提取读IOPS
        read_iops=$(grep -oPi 'read: IOPS=\K[\d.]+' "$result_file")

        # 提取写IOPS
        write_iops=$(grep -oPi 'write: IOPS=\K[\d.]+' "$result_file")

        # 提取磁盘使用率
        disk_util=$(grep -oP 'util=\K[\d.]+' "$result_file")

    else
        echo "no file $1"
    fi

    #echo "读IOPS: $read_iops"
    #echo "读带宽: $read_bw"
    #echo "写IOPS: $write_iops"
    #echo "写带宽: $write_bw"
    #echo "磁盘使用率: $disk_util%"
}

# 生成表格行
generate_table_row() {
    local test=$1
    local read_bandwidth=$2
    local write_bandwidth=$3
    local read_iops=$4
    local write_iops=$5
    local disk_usage=$6

    echo "<tr>"
    echo "<td>$test</td>"
    echo "<td>${read_bandwidth:-/}</td>"
    echo "<td>${write_bandwidth:-/}</td>"
    echo "<td>${read_iops:-/}</td>"
    echo "<td>${write_iops:-/}</td>"
    echo "<td>${disk_usage:-/}</td>"
    echo "</tr>"
}

# 生成表格内容
generate_table_content() {
	# 提取结果信息
	extract_info_single "/tmp/fio_read.txt" "read"
	generate_table_row "顺序读" "$bw" "" "$iops" "" "$disk_util%"

	extract_info_single "/tmp/fio_write.txt" "write"
	generate_table_row "顺序写" "" "$bw" "" "$iops" "$disk_util%"

	extract_info_mix "/tmp/fio_rw_rwmixread.txt"
	generate_table_row "混合读写" "$read_bw" "$write_bw" "$read_iops" "$write_iops" "$disk_util%"

	extract_info_single "/tmp/fio_randread.txt" "randread"
	generate_table_row "随机读" "$bw" "" "$iops" "" "$disk_util%"

	extract_info_single "/tmp/fio_randwrite.txt" "randwrite"
	generate_table_row "随机写" "" "$bw" "" "$iops" "$disk_util%"

	extract_info_mix "/tmp/fio_randrw_rwmixread.txt"
    generate_table_row "混合随机读写" "$read_bw" "$write_bw" "$read_iops" "$write_iops" "$disk_util%"

}
run_iperf3(){
	echo "====执行iperf压测====="
	# 判断是否能够ping通远程IP
	ping -c 1 "$remote_ip" > /dev/null

	if [ $? -eq 0 ]; then
	    echo "Ping$remote_ip成功，开始进行iperf3测试"
	    # 执行iperf3进行网络压测，参数为带宽1000M
	    if iperf3 -c "$remote_ip" -p "$remote_port" -t 3; then
			iperf3_command="iperf3 -c $remote_ip -p $remote_port -n 10G"
			echo "开始iperf3压测,执行: $iperf3_command"
			$iperf3_command > /tmp/iperf_results.txt

			echo "<br><h2>iperf3 info</h2><pre>" >> $html_file
			cat /tmp/iperf_results.txt >> $html_file
			echo "</pre>" >> $html_file
			echo -e "${GREEN}iperf3压测结果已输出: $html_file ${NC}"

	    else
	        echo -e "${RED}iperf3压测失败${NC}"
			echo -e "${YELLOW}建议检查防火墙是否关闭、远程iperf3服务是否开启、远程端口配置是否正确${NC}"
			exit
	    fi
	else
	    echo "无法ping通远程IP:"$remote_ip""
		exit
	fi
}

run_all_fio(){
	echo "====执行fio压测====="
	#默认磁盘压测参数是8k，1G，50并发，300s，可以根据实际需要调整
	run_fio "$fio_bs" "$fio_size" "$fio_numjobs" "$fio_rumtime" "read" "fio_read"
	run_fio "$fio_bs" "$fio_size" "$fio_numjobs" "$fio_rumtime" "write" "fio_write"
	run_fio "$fio_bs" "$fio_size" "$fio_numjobs" "$fio_rumtime" "rw" "fio_rw_rwmixread" "$fio_rwmixread"
	run_fio "$fio_bs" "$fio_size" "$fio_numjobs" "$fio_rumtime" "randread" "fio_randread"
	run_fio "$fio_bs" "$fio_size" "$fio_numjobs" "$fio_rumtime" "randwrite" "fio_randwrite"
	run_fio "$fio_bs" "$fio_size" "$fio_numjobs" "$fio_rumtime" "randrw" "fio_randrw_rwmixread" "$fio_rwmixread"
}

check_os
if [[ $remote_ip == 'nofio' ]];then
	echo "INFO: skip fio test."
else
	check_fio
	if [[ ! -e "/tmp/fio_read.txt" ]];then
		run_all_fio
	fi
fi
generate_table_content >> $html_file
cat <<EOF >> $file_name
</table>
EOF


if [[ -n "$remote_ip" && "$remote_ip" != "nofio" ]];then
	check_iperf3
	run_iperf3
fi


# HTML 文件尾部
cat <<EOF >> $file_name
</body>
</html>
EOF

echo "生成文件: $file_name"

