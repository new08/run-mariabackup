#!/bin/sh

# 创建数据库备份账号
# CREATE USER 'mariabackup'@'localhost' IDENTIFIED BY 'Se1496';
# MariaDB < 10.5:
#   GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'mariabackup'@'localhost';
# MariaDB >= 10.5:
#   GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'mariabackup'@'localhost';
# FLUSH PRIVILEGES;
#
# Usage:
# sh run-mariabackup.sh

# 数据库备份账号
MYSQL_USER=mariabackup
# 数据库备份账号密码
MYSQL_PASSWORD=Se1496
# 数据库 HOST
MYSQL_HOST=localhost
# 数据库端口
MYSQL_PORT=3306
# 备份路径
BACKDIR=/u3/backup/mariabackup
# 完整备份的周期，单位是秒 7d=604800s
FULLBACKUPCYCLE=604800 # Create a new full backup every X seconds
# 完整备份的保留份数
KEEP=3  # Number of additional backups cycles a backup should be kept for.

# 下面的不要改
BACKCMD=mariabackup # Galera Cluster uses mariabackup instead of xtrabackup.
GZIPCMD=gzip  # pigz (a parallel implementation of gzip) could be used if available.
STREAMCMD=xbstream # sometimes named mbstream to avoid clash with Percona command
LOCKDIR=/tmp/mariabackup.lock

# 解锁
ReleaseLockAndExitWithCode () {
  if rmdir $LOCKDIR
  then
    echo "Lock directory removed"
  else
    echo "Could not remove lock dir" >&2
  fi
  exit $1
}

# 加锁
GetLockOrDie () {
  if mkdir $LOCKDIR
  then
    echo "Lock directory created"
  else
    echo "Could not create lock directory" $LOCKDIR
    echo "Is another backup running?"
    exit 1
  fi
}

# mariabackup 命令行参数
USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST} --port=${MYSQL_PORT}"
# Arguments may include amongst others:
# --parallel=2  => Number of threads to use for parallel datafiles transfer. Default value is 1.
# --galera-info => Creates the xtrabackup_galera_info file which contains the local node state
# at the time of the backup. Option should be used when performing the backup of MariaDB Galera Cluster.
ARGS=""
BASEBACKDIR=$BACKDIR/base
INCRBACKDIR=$BACKDIR/incr
START=`date +%s`

echo "----------------------------"
echo
echo "run-mariabackup.sh: MySQL backup script"
echo "started: `date`"
echo

# 备份前环境检查
# 1. 检查备份文件夹结构
if test ! -d $BASEBACKDIR
then
  mkdir -p $BASEBACKDIR
fi

# Check base dir exists and is writable
if test ! -d $BASEBACKDIR -o ! -w $BASEBACKDIR
then
  error
  echo $BASEBACKDIR 'does not exist or is not writable'; echo
  exit 1
fi

if test ! -d $INCRBACKDIR
then
  mkdir -p $INCRBACKDIR
fi

# check incr dir exists and is writable
if test ! -d $INCRBACKDIR -o ! -w $INCRBACKDIR
then
  error
  echo $INCRBACKDIR 'does not exist or is not writable'; echo
  exit 1
fi

# 2. 检查数据库是否可以访问
if [ -z "`mysqladmin $USEROPTIONS status | grep 'Uptime'`" ]
then
  echo "HALTED: MySQL does not appear to be running."; echo
  exit 1
fi

if ! `echo 'exit' | /usr/bin/mysql -s $USEROPTIONS`
then
  echo "HALTED: Supplied mysql username or password appears to be incorrect (not copied here for security, see script)"; echo
  exit 1
fi

# 3. 检查是否重复执行备份脚本
GetLockOrDie

# 备份前环境检查结束
echo "Check completed OK"

# 寻找最后一次完整备份
LATEST=`find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1`

AGE=`stat -c %Y $BASEBACKDIR/$LATEST/backup.stream.gz`

# 存在一个完整备份，且最后一个备份文件的修改时间距现在小于一个完整备份周期时间
if [ "$LATEST" -a `expr $AGE + $FULLBACKUPCYCLE + 5` -ge $START ]
then
  # 进行增量备份
  echo 'New incremental backup'
  # Create an incremental backup

  # 创建增量备份文件夹
  # Check incr sub dir exists
  # try to create if not
  if test ! -d $INCRBACKDIR/$LATEST
  then
    mkdir -p $INCRBACKDIR/$LATEST
  fi

  # Check incr sub dir exists and is writable
  if test ! -d $INCRBACKDIR/$LATEST -o ! -w $INCRBACKDIR/$LATEST
  then
    echo $INCRBACKDIR/$LATEST 'does not exist or is not writable'
    ReleaseLockAndExitWithCode 1
  fi

  # 寻找该完整备份的最后一个增量备份
  LATESTINCR=`find $INCRBACKDIR/$LATEST -mindepth 1  -maxdepth 1 -type d | sort -nr | head -1`
  if [ ! $LATESTINCR ]
  then
    # This is the first incremental backup
    INCRBASEDIR=$BASEBACKDIR/$LATEST
  else
    # This is a 2+ incremental backup
    INCRBASEDIR=$LATESTINCR
  fi

  TARGETDIR=$INCRBACKDIR/$LATEST/`date +%F_%H-%M-%S`
  mkdir -p $TARGETDIR

  # 进行增量备份
  # --extra-lsndir=$TARGETDIR: mariabackup 输出到 stdout 时，默认会把 xtrabackup_checkpoints 也输出到 stream。
  # 用 extra-lsndir 可以将 xtrabackup_checkpoints 额外保存到指定路径
  # Create incremental Backup
  $BACKCMD --backup $USEROPTIONS $ARGS --extra-lsndir=$TARGETDIR --incremental-basedir=$INCRBASEDIR --stream=$STREAMCMD | $GZIPCMD > $TARGETDIR/backup.stream.gz
else
  # 进行完整备份
  echo 'New full backup'

  TARGETDIR=$BASEBACKDIR/`date +%F_%H-%M-%S`
  mkdir -p $TARGETDIR

  # Create a new full backup
  $BACKCMD --backup $USEROPTIONS $ARGS --extra-lsndir=$TARGETDIR --stream=$STREAMCMD | $GZIPCMD > $TARGETDIR/backup.stream.gz
fi

# 清理过期的备份文件
MINS=$(($FULLBACKUPCYCLE * ($KEEP + 1 ) / 60))
DAYS=$(($FULLBACKUPCYCLE * ($KEEP + 1 ) / 8640))
echo "Cleaning up old backups (older than $DAYS days) and temporary files"

# Delete old backups
for DEL in `find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -mmin +$MINS -printf "%P\n"`
do
  echo "deleting $DEL"
  rm -rf $BASEBACKDIR/$DEL
  rm -rf $INCRBACKDIR/$DEL
done

SPENT=$((`date +%s` - $START))
echo
echo "took $SPENT seconds"
echo "completed: `date`"

# 解锁
ReleaseLockAndExitWithCode 0
