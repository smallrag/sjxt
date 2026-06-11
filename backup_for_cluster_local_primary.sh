#!/bin/bash

#生效环境变量
if [ -f ~/.bashrc ];then
    source ~/.bashrc
else 
    source ~/.Vastbase
fi

##定义变量,请按实际修改
backup_path=/data/backup
instance_name=BACKUP
backup_log_path=/home/vastbase/vbbackup
backup_log=/home/vastbase/vbbackup/backup.log 
node_log=/home/vastbase/vbbackup/db_node.log
cur_time=`date +'%Y-%m-%d %H:%M:%S'`
job_num=4
primary_or_standby=`vsql --pset=pager=off  -q -A -t  -c "select case when pg_is_in_recovery()='f' then 'primary' else 'standby' end;"`
week_day=`date +%w`
first_full_day=0



#创建日志目录
if [ ! -d $backup_log_path ];then   
    mkdir -p $backup_log_path
fi

if [ ! -f $node_log ];then
    touch $node_log
    echo "$cur_time,init_time,none" >> $node_log 
fi

#初始化instance
#add_instance(){
#vb_probackup init -B $backup_path
#vb_probackup add-instance -B $backup_path -D /data/vastdata --instance instance_name 
#}

#备份配置
backup_policy(){
vb_probackup set-config -B $backup_path --instance $instance_name --retention-window=7 --retention-redundancy=2 --compress-algorithm zlib --compress-level 5 --log-level-file=info --log-directory=$backup_log_path --log-filename=full_backup-%Y%m%d.log 
}

#全量备份
full_backup(){
vb_probackup backup -B $backup_path --instance $instance_name  --stream -b full -j $job_num
}

#增量备份
incre_backup(){
vb_probackup backup -B $backup_path --instance $instance_name   --stream -b PTRACK -j $job_num
}

#删除归档的wal文件，wal文件保留7~14天
delete_backup_wal(){
vb_probackup delete -B $backup_path --instance $instance_name --delete-expired --delete-wal --wal-depth 4 
}

#查看备份
show_backup(){
vb_probackup show -B $backup_path --instance $instance_name
}

#清理cbm信息
clean_cbm(){
cbm_lsn=`vb_probackup show -B $backup_path --instance $instance_name --format=json|grep start-lsn|tail -1|sed  -e 's/"//g' -e 's/,//g' -e 's/ //g'|awk -F ":" '{print $2}'`
vsql postgres --pset=pager=off -f $backup_log -q -A -t  -c "select clock_timestamp()::timestamp(0) ||',clean_cbm,'||pg_cbm_recycle_file('$cbm_lsn');"
}

clean_standby_cbm(){
vsql postgres --pset=pager=off -f $backup_log -q -A -t  -c "select clock_timestamp()::timestamp(0) ||',clean_cbm,'||pg_cbm_recycle_file(pg_cbm_tracked_location());"
}

yest_result=`tail -1 $node_log|awk -F "," '{print $3}'`

#主库做备份,每周日做一次全备，其余为增量备份，切换后当晚做一次全备份
#备库只删除归档和CBM  

backup_policy  >>  $backup_log
if [ $primary_or_standby == 'primary' ];then
   if [ $yest_result != 'full_backup' ];then
        week_day=`date +%w`
        #判断是否周日
        if [ $week_day == $first_full_day ];then
          echo "$cur_time,Starting Full Backup">>  $backup_log
          full_backup  >> $backup_log
          echo "$cur_time,End Full Backup">>  $backup_log
          echo "$cur_time,$primary_or_standby,full_backup" >> $node_log 
            sleep 1
          echo "$cur_time,Starting Delete Backup and Wal" >>  $backup_log
          delete_backup_wal  >> $backup_log
          echo "$cur_time,End Delete Backup and Wal" >>  $backup_log
            sleep 1
		  echo "$cur_time,Starting clean cbm info" >>  $backup_log
          clean_cbm  >> $backup_log
          echo "$cur_time,End clean cbm info" >>  $backup_log
            show_backup  >> $backup_log

        else 
            if [ $yest_result == 'incre_backup' ];then
              echo "$cur_time,Starting incremental page backup" >>  $backup_log
              incre_backup  >> $backup_log
              echo "$cur_time,End incremental page backup" >>  $backup_log
              echo "$cur_time,$primary_or_standby,incre_backup" >> $node_log 
              sleep 1
              echo "$cur_time,Starting Delete Backup and Wal " >>  $backup_log
              delete_backup_wal  >> $backup_log
              echo "$cur_time,End Delete Backup and Wal      " >>  $backup_log
              sleep 1
              echo "$cur_time,Starting clean cbm info" >>  $backup_log
              clean_cbm  >> $backup_log
              echo "$cur_time,End clean cbm info" >>  $backup_log
            else
              echo "$cur_time,Starting Full Backup">>  $backup_log
              full_backup  >> $backup_log
              echo "$cur_time,End Full Backup">>  $backup_log
              echo "$cur_time,$primary_or_standby,full_backup" >> $node_log    
		      echo "$cur_time,Starting clean cbm info" >>  $backup_log
              clean_cbm  >> $backup_log
              echo "$cur_time,End clean cbm info" >>  $backup_log			  
                show_backup  >> $backup_log
            fi              
        fi    
   else    
        echo "$cur_time,Starting incremental page backup" >>  $backup_log
        incre_backup  >> $backup_log
        echo "$cur_time,End incremental page backup" >>  $backup_log
        echo "$cur_time,$primary_or_standby,incre_backup" >> $node_log 
        sleep 1
        echo "$cur_time,Starting Delete Backup and Wal" >>  $backup_log
        delete_backup_wal  >> $backup_log
        echo "$cur_time,End Delete Backup and Wal" >>  $backup_log
        sleep 1
		echo "$cur_time,Starting clean cbm info" >>  $backup_log
        clean_cbm  >> $backup_log
        echo "$cur_time,End clean cbm info" >>  $backup_log
        show_backup  >> $backup_log
    fi
else
        echo "$cur_time,Starting Delete Backup and Wal" >>  $backup_log
        delete_backup_wal  >> $backup_log
        echo "$cur_time,End Delete Backup and Wal" >>  $backup_log
        echo "$cur_time,$primary_or_standby,delete_backup_wal" >> $node_log 
        sleep 1
		echo "$cur_time,Starting clean standby cbm info" >>  $backup_log
        clean_standby_cbm  >> $backup_log
        echo "$cur_time,End clean standby cbm info" >>  $backup_log
        show_backup  >> $backup_log
fi


