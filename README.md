# README

*forked from [jmfederico/run-xtrabackup.sh](https://gist.github.com/jmfederico/1495347)*

Note: have tested on CentOS 7.9 with MariaDB 10.4

## Links

[Full Backup and Restore with Mariabackup](https://mariadb.com/kb/en/library/full-backup-and-restore-with-mariabackup/)

[Incremental Backup and Restore with Mariabackup](https://mariadb.com/kb/en/library/incremental-backup-and-restore-with-mariabackup/)

---

## Install mariabackup

    sudo yum install mariadb-backup

## Create a backup user

```sql
-- See https://mariadb.com/kb/en/mariabackup-overview/#authentication-and-privileges
CREATE USER 'mariabackup'@'localhost' IDENTIFIED BY 'Se1496';
-- MariaDB < 10.5:
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'mariabackup'@'localhost';
-- MariaDB >= 10.5:
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'mariabackup'@'localhost';
FLUSH PRIVILEGES;
```

## Usage

    sh run-mariabackup.sh

## Crontab

    #MySQL Backup
    0 0 * * * sh /u3/backup/run-mariabackup.sh > /u3/backup/mariabackup/run-mariabackup.sh.out 2>&1

---

## Restore Example

每次完整备份，都会将资料保存到 .../base/$(当前时间) 路径。    
每次增量备份，都会将资料保存到 .../incr/$(上次完整备份时间) 路径。    

    tree /u3/backup/mariabackup/
    /u3/backup/mariabackup/
    ├── base
    │   └── 2018-10-23_10-07-31
    │       ├── backup.stream.gz
    │       └── xtrabackup_checkpoints
    └── incr
        └── 2018-10-23_10-07-31
            ├── 2018-10-23_10-08-49
            │   ├── backup.stream.gz
            │   └── xtrabackup_checkpoints
            └── 2018-10-23_10-13-58
                ├── backup.stream.gz
                └── xtrabackup_checkpoints

```bash
# decompress
cd /u3/backup/mariabackup/
for i in $(find . -name backup.stream.gz | grep '2018-10-23_10-07-31' | xargs dirname); \
do \
mkdir -p $i/backup; \
zcat $i/backup.stream.gz | mbstream -x -C $i/backup/; \
done

# prepare
mariabackup --prepare --target-dir base/2018-10-23_10-07-31/backup/ --user backup --password "YourPassword" --apply-log-only
mariabackup --prepare --target-dir base/2018-10-23_10-07-31/backup/ --user backup --password "YourPassword" --apply-log-only --incremental-dir incr/2018-10-23_10-07-31/2018-10-23_10-08-49/backup/
mariabackup --prepare --target-dir base/2018-10-23_10-07-31/backup/ --user backup --password "YourPassword" --apply-log-only --incremental-dir incr/2018-10-23_10-07-31/2018-10-23_10-13-58/backup/

# stop mairadb
service mariadb stop

# empty datadir
mv /data/mysql/ /data/mysql_bak/

# copy-back
mariabackup --copy-back --target-dir base/2018-10-23_10-07-31/backup/ --user backup --password "YourPassword" --datadir /data/mysql/

# fix privileges
chown -R mysql:mysql /data/mysql/

# start mariadb
service mariadb start

# done!
```
