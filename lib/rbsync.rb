# encoding: utf-8


require 'fileutils'
# Synchronize files src to dest . 
# this class can sync files and recuresively
# options are
# +sync update file only
# +no overwrite when dist files are newer than src
# +sync by file digest hash , not useing filename
#
# == usage
# === mirror files
# 同期元と同期先を同じにする
#           require 'rbsync'
#           rsync =RbSync.new
#           rsync.sync( "src", "dest" )
# === mirror updated only files
# 同期先に、同期元と同名のファイルがあったら、更新日時を調べる。新しいモノだけをコピーする．
#           require 'rbsync'
#           rsync =RbSync.new
#           rsync.sync( "src", "dest",{:update=>true} )
# === using exclude pattern
# 同期先と同期元を同じにする，但し、*.rb / *.log の拡張子は除外する．
#           require 'rbsync'
#           rsync =RbSync.new
#           rsync.sync( "src", "dest",{:excludes=>["*.log","*.bak"]} )
# == sync by another name  if file name confilicts
# 名前が衝突した場合で、ファイルを書換える時は，転送元のファイルを別名で転送する
# windows のファイルコピーっぽい動作
# send src file with anothername.
# before sync
# |src  | test.txt | 2011-06-14
# |dest | test.txt | 2011-06-12
# after sync
# |src  | test.txt    | 2011-06-14
# |dest | test(1).txt | 2011-06-14 # same to src
# |dest | test.txt    | 2011-06-12
# == sync with backup 
# 名前が衝突した場合で、ファイルを書換える場合転送先のファイルを別名で保存してから転送する
# before sync
# |src  | test.txt | 2011-06-14
# |dest | test.txt | 2011-06-12
# after sync
# |src  | test.txt                   | 2011-06-14
# |dest | test.txt                   | 2011-06-14 # same to src
# |dest | test_20110614022255.txt    | 2011-06-12 # moved
#
#
# ==special usage , sync by file cotetets 
# if directory has a same file with different file name. insted of filename , sync file by file hash
# when files are theses,
#  |src| test.txt | "47bce5c74f589f4867dbd57e9ca9f808" |
#  |dst| test.bak | "47bce5c74f589f4867dbd57e9ca9f808" |
# :check_hash results no effect.
# ディレクトリ内のファイル名をうっかり変えてしまったときに使う．ファイル名でなく、ファイルの中身を比較して同期する．
#  |src| test.txt | "47bce5c74f589f4867dbd57e9ca9f808" |
#  |dst| test.bak | "47bce5c74f589f4867dbd57e9ca9f808" |
# の場合何もおきません
#           require 'rbsync'
#           rsync =RbSync.new
#           rsync.sync( "src", "dest",{:check_hash=>true} )
# === directory has very large file ,such as mpeg video
# using with :check_hash=>true
# checking only head of 1024*1024 bytes to distinguish src / dest files.this is for speed up.
# FileUtils::cmp is reading whole file. large file will take time.With :hash_limit_size Rbsync read only head of files for comparing.
# 巨大なファイルだと，全部読み込むのに時間が掛かるので、先頭1024*1024 バイトを比較してOKとする.写真とかはコレで十分
# ファイル名を書換えてしまってコンテンツ内容の比較だけで使う。
# :check_hash=>true とペアで使います
#           require 'rbsync'
#           rsync =RbSync.new
#           rsync.sync( "src", "dest",{:check_hash=>true,:hash_limit_size=1024*1024} )
# 
# === sync both updated files
# To sync both, call sync methods twice 
# 双方向に同期させたい場合は２回起動する．
#           require 'rbsync'
#           rsync =RbSync.new
#           rsync.updated_file_only = true
#           rsync.sync( "src", "dest" )
#           rsync.sync( "dest", "src" )# swap src to dest , dest to src
#### TODO: 
## FileUtils/Dir.chdir をSSH対応に切替える
## progress 表示のために fileutils.copy を 自作する
class RbSync
  attr_accessor :conf
  # for ruby 1.8.7 (2008-08-11 patchlevel 72) [i386-cygwin]
  # File.dirname  of cygwin doesn't work corrently for JAPANESE hiragana pathname
  # Cygwinの日本語UTF8/SJIS環境だと「ひらがな」パス名が正しく扱えないのでmonkey patch
  if ((RUBY_PLATFORM =~ /cygwin/) and RUBY_VERSION == "1.8.7")then
    def File.dirname(e)
      paths = e.split("/")
      paths.pop
      paths.join("/")
    end
    def FileUtils.mkdir_p(e)
      `mkdir -p '#{e}'`
      `touch '#{e}' -d '#{Time.now}'`
    end
  end
  def initialize()
    @conf ={}
    @conf[:update] = false
    @conf[:excludes] = []
    @conf[:preserve] = true
    @conf[:overwrite] = true
    @conf[:strict] = true
  end
  # collect file paths. paths are relatetive path.
  def find_as_relative(dir_name,excludes=[])
    files =[]
    excludes = [] unless excludes
    #todo write this two line . exculude initialize test
    excludes = excludes.split(",") if excludes.class == String
    excludes = [excludes]          unless excludes.class == Array
    
    Dir.chdir(dir_name){ 
      files = Dir.glob "./**/*", File::FNM_DOTMATCH
      exclude_files =[]
      exclude_files = excludes.map{|g| Dir.glob "./**/#{g}",File::FNM_DOTMATCH } 
      files = files.reject{|e| File.directory?(e)  }
      files = files - exclude_files.flatten
    }
    files = files.reject{|e| [".",".."].any?{|s| s== File::basename(e)  }}
  end
  # compare two directory by name and FileUtis.cmp
  def find_files(src,dest,options)
    src_files  = self.find_as_relative(  src, options[:excludes] )
    dest_files = self.find_as_relative( dest, options[:excludes] )

    # output target files
    puts "　　元フォルダ:"  +  src_files.size.to_s + "件" if self.debug?
    puts "同期先フォルダ:"  + dest_files.size.to_s + "件" if self.debug?
    #pp src_files if self.debug?
    sleep 1 if self.debug?

    #両方にあるファイル名で中身が違うもので src の方が古いもの
    same_name_files = (dest_files & src_files)
    same_name_files.reject!{|e|
        #ファイルが同じモノは省く
        next unless File.exists?( File.expand_path(e,dest))
        puts "compare file bin.  #{e}" if self.debug? || self.verbose?
        $stdout.flush if self.debug?
        FileUtils.cmp( File.expand_path(e,src) , File.expand_path(e,dest) ) 
    } if options[:strict]
    same_name_files.reject!{|e|
        #ファイルサイズが同じモノを省く（全部比較する代替手段）
        next unless File.exists?( File.expand_path(e,dest))
        puts "size/mtime compare #{e}" if self.debug? || self.verbose?
        File.size(File.expand_path(e,src)) == File.size( File.expand_path(e,dest))
        #&& File.mtime(File.expand_path(e,src)) == File.mtime( File.expand_path(e,dest) )
    } unless options[:strict]
    if options[:update] then
      same_name_files= same_name_files.select{|e|
          puts "mtime is newer   #{e}" if self.debug? || self.verbose?
          (File.mtime(File.expand_path(e,src)) > File.mtime( File.expand_path(e,dest)))
      }
    end
    if options[:overwrite] == false then
      same_name_files= same_name_files.reject{|e|
          puts "can over write?  #{e}" if self.debug? || self.verbose?
          (File.exists?(File.expand_path(e,src)) && File.exists?( File.expand_path(e,dest)))
      }
    end
    $stdout.flush if self.debug?
    files_not_in_dest = (src_files - dest_files)
    #files
    files =[]
    files = (files_not_in_dest + same_name_files ).flatten
    files
  end
  def sync_by_hash(src,dest,options={})
    src_files   = collet_hash(find_as_relative(src, options[:excludes]), src, options)
    dest_files  = collet_hash(find_as_relative(dest,options[:excludes]),dest, options)
    target  = src_files.keys - dest_files.keys
    target = target.reject{|key|
      e = src_files[key].first
      options[:update] && 
      File.exists?( File.expand_path(e,dest)) &&
      (File.mtime(File.expand_path(e,src)) < File.mtime( File.expand_path(e,dest)))
    }
    if options[:overwrite] == false then
      target = target .reject{|key|
          e = src_files[key].first
          (File.exists?(File.expand_path(e,src)) && File.exists?( File.expand_path(e,dest)))
      }
    end
    puts "同期対象ファイル" if self.debug?
    puts target.each{|key|puts src_files[key].first} if self.debug?
    puts "同期対象はありません" if self.debug? and target.size==0

    files= target.map{|key|
        e = src_files[key].first
        [File.expand_path(e,src) , File.expand_path(e,dest)]
    }
    self.copy_r(files)

    ret = files.map{|e|
      FileTest.exist?(e[1])
    }
    puts "同期が終りました"     if ret.select{|e|!e}.size == 0 && self.debug?
    puts "同期に失敗したみたい" if ret.select{|e|!e}.size != 0 && self.debug?
  end
  def collet_hash(file_names,basedir,options={})
    #prepare
    require 'thread'
    self.patch_digest_base
    threads =[]
    output = Hash.new{|s,key| s[key]=[] }
    q      = Queue.new
    limitsize = options[:hash_limit_size]
    # compute digests
    file_names.each{|e| q.push e }
    3.times{
      threads.push(
        Thread.start{
          while(!q.empty?)
            name = q.pop
            #$stdout.puts "reading #{name}" if options[:verbose]
            #$stdout.flush if options[:verbose]
            hash = compute_digest_file(File.expand_path(name,basedir),limitsize)
            output[hash].push name
          end
        }
      )
    }
    if options[:verbose] then
      t = Thread.start{
          until(q.empty?)
            puts( "#{q.size}/#{file_names.size}");
            $stdout.flush;
            sleep 1;
          end
      } 
      threads.push(t )
    end
    threads.each{|t|t.join}
    return output
  end
  def patch_digest_base()
      require 'digest/md5'
      s = %{
      class Digest::Base
        def self.open(path,limitsize=nil)
          obj = new
          File.open(path, 'rb') do |f|
            buf = ""
            while f.read(256, buf)
              obj << buf
              break if f.pos > (limitsize or f.pos+1)
            end
          end
          return obj
        end
      end
      }
      eval s
  end
  # compute digest md5 
  # ==limitsize
  #   If file size is very large,
  #   and a few bytes at head of file is enough to compare.
  #   for speed-up, Set limit size to enable to avoid reading a whole of file.
  #   もしファイルがとても巨大で、かつ、先頭の数キロバイトが比較に十分であれば、limitsize 以降をスキップする
  def compute_digest_file(filename, limitsize=nil)
      Digest::MD5.open(filename,limitsize).hexdigest
  end
  
  # called from sync
  def sync_normally(src,dest,options={})
    Thread.abort_on_exception = true if self.debug?
    files = self.find_files(src,dest,options)
    puts "同期対象のファイルはありません" if self.debug? && files.size==0
    return true if files.size == 0
    puts "次のファイルを同期します" if self.debug?
    pp files                        if self.debug?
    
    #srcファイルをdestに上書き
    #todo options を取り出す
    self.copy_r(files.map{|e|[File.expand_path(e,src) , File.expand_path(e,dest)]})
    
    #checking sync result
    files = self.find_files(src,dest,options)

    puts "同期が終りました"       if files.size == 0 && self.debug?
    puts "同期に失敗がありました" if files.size != 0 && self.debug?
    pp files                      if files.size != 0 && self.debug?
    return files.size == 0
  end
  # 同期先に同名ファイルがあったらファイルを別名にバックアップしてから転送します
  def sync_with_backup(src,dest,options)
    # 上書き付加の場合
    # 
    #ファイル一覧を取得する
    files = find_as_relative(src,options[:excludes])
    #中身が同じモノを排除
    files = files.reject{|e|
      FileUtils.cmp(File.expand_path(e,src) , File.expand_path(e,dest))
    }
    #更新日が当たらしいモノを排除
    if options[:update] then
      #更新日が当たらしいモノを排除
      files = files.reject{|e|
        File.mtime(File.expand_path(e,src)) < File.mtime(File.expand_path(e,dest))
      }
    end
    #別名をつける
    files = files.map{|e|
      extname = File.extname(e)
      basename = File.basename(e).gsub(extname,"")
        # 同名のファイルがあった場合
        # ファイルをリネームする
        if File.exists?(File.expand_path(e,dest)) then
            candidate = File.expand_path("#{basename}_#{Time.now.strftime('%Y%m%d%H%M%S')}#{extname}",dest)
            File.rename( File.expand_path(e,dest),candidate )
        end
      [File.expand_path(e,src) , File.expand_path(e,dest)]
    }
    #コピーする
    self.copy_r(files)
  end
  # 別名で名前をつけて転送する
  def sync_by_anothername(src,dest,options)
    # 上書き付加の場合
    # 
    #ファイル一覧を取得する
    files = find_as_relative(src,options[:excludes])
    #中身が同じモノを排除
    files = files.reject{|e|
      FileUtils.cmp(File.expand_path(e,src) , File.expand_path(e,dest))
    }
    if options[:update] then
      #更新日が当たらしいモノを排除
      files = files.reject{|e|
        File.mtime(File.expand_path(e,src)) < File.mtime(File.expand_path(e,dest))
      }
    end
    #別名をつける
    files = files.map{|e|
      extname = File.extname(e)
      basename = File.basename(e).gsub(extname,"")
      candidate = ""
      100.times{|i|
        candidate = File.expand_path("#{basename}(#{i+1})#{extname}",dest)
        break unless File.exists?(File.expand_path(candidate,dest))
        raise "upto #{i} files are already exists ." if  i >=1000
        next FileUtils.cmp(File.expand_path(e,src) , File.expand_path(candidate,dest))
      }
      [File.expand_path(e,src) , File.expand_path(candidate,dest)]
    }
    #コピーする
    self.copy_r(files)
  end
  def copy_r(files)
    #
    puts ("copy #{files.size} files") if(@conf[:progress])
    $stdout.flush                     if(@conf[:progress])

    files.each_with_index{|e,i|
      #show
        puts ("start #{i+1}/#{files.size}")if(@conf[:progress])
        $stdout.flush if(@conf[:progress])
      #main
      tmp_name = "#{e[1]}.copy_tmp"
      FileUtils.rm(tmp_name) if File.exists?(tmp_name)
      copy_thread = Thread.start{
        FileUtils.mkdir_p File.dirname(e[1]) unless File.exists?(File.dirname(e[1]))
        ## todo copy file as stream for progress
        begin
          FileUtils.copy( e[0] , tmp_name ,{:preserve=>self.preserve?,:verbose=>self.verbose? } )
          FileUtils.mv(tmp_name,e[1])
          rescue Errno::EACCES => err
          puts e[1];puts err
        end
      }
      
      #progress of each file
      puts "#{e[0]}" if self.verbose? || self.debug?
      progress_thread = nil
      if(@conf[:progress])
        progress_thread = Thread.start{
          bar = ProgressBar.new
          bar.size = 30
          src_size = File.size(e[0])
          dst_size = -1
          bar.start("copying #{e[0]} \r\n   to #{e[1]}")
          cnt = 0
          dst_name = tmp_name
          while(src_size!=dst_size)
            dst_name = e[1] if File.exists?(e[1]) and not File.exists?(tmp_name)
            unless File.exists?(dst_name) then
              cnt = cnt + 1
              if cnt > 25 then
                puts "copying #{e[1]} is terminated.\r\n timeout error"
                throw Error
                break
              end
              sleep 0.2
              next
            end
            src_size = File.size(e[0]).to_f
            dst_size = File.size(dst_name).to_f
            break if src_size == 0 # preven zero divide
            # next  if dst_size == 0 # preven zero divide
            percent = dst_size/src_size*100
            bar.progress(percent.to_int)
            sleep 0.6
          end
          src_size = File.size(e[0]).to_f
          dst_size = File.size(e[1]).to_f
          percent = dst_size/src_size*100
          bar.progress(percent.to_int)
          bar.end("done")
        }
      end
      progress_thread.join if progress_thread 
      copy_thread.join
    }
  end
  def sync(src,dest,options={})
    options[:excludes]        = self.excludes.push(options[:excludes]).flatten.uniq if options[:excludes]
    options[:update]          = @conf[:update] if options[:update] == nil
    options[:strict]          = @conf[:strict] if options[:strict] == nil
    options[:check_hash]      = options[:check_hash] or @conf[:check_hash]
    options[:hash_limit_size] = @conf[:hash_limit_size]                       if options[:hash_limit_size] == nil
    options[:overwrite]       = @conf[:overwrite]                             if options[:overwrite] == nil
    options[:overwrite]       = false                                         if options[:no_overwrite]
    FileUtils.mkdir_p dest unless File.exists? dest
    if options[:rename]
      return self.sync_by_anothername(src,dest,options)
    elsif options[:backup]
      return self.sync_with_backup(src,dest,options)
    elsif options[:check_hash]
      return self.sync_by_hash(src,dest,options)
    else
      return self.sync_normally(src,dest,options)
    end
  end
  
  #for setting

  def debug_mode?
    self.conf[:debug] ==true
  end
  def verbose?
    self.conf[:verbose] == true
  end
  def hash_limit_size
    @conf[:hash_limit_size]
  end

  # flag true or false
  def debug_mode=(flag)
    self.conf[:debug] = flag
  end
  # flag true or false
  def verbose=(flag)
    self.conf[:verbose] = flag
    $stdout.sync = flag
  end
  #
  # flag true or false
  def updated_file_only=(flag)
    @conf[:update] = flag
  end
  #
  # flag true or false
  def check_hash=(flag)
    @conf[:use_md5_digest] = flag
  end
  def hash_limit_size=(int_byte_size)
    @conf[:hash_limit_size] = int_byte_size
  end
  
  def excludes=(glob_pattern)
    @conf[:excludes].push glob_pattern
  end
  def excludes
    @conf[:excludes]
  end
  def preserve=(flag)
    @conf[:preserve] = false
  end
  def preserve?
    @conf[:preserve]
  end
  def overwrite=(flag)
    @conf[:overwrite] = flag
  end
  def overwrite?
    @conf[:overwrite]
  end

  #aliases

  alias debug? debug_mode?
  alias debug= debug_mode=
  alias update= updated_file_only=
  alias newer=   updated_file_only=
end

# ==プログレスバーを表示する．
#      prg= ProgressBar.new
#      prg.show_percent = true
#      prg.size = 60
#      prg.start("downloading\n")
#      100.times{|i|
#        prg.progress(i, "#{i}/100")
#        sleep 0.015
#      }
#      prg.end("done")
class ProgressBar
  attr_accessor :size, :out, :bar_char_undone, :bar_char_done, :show_percent
  def initialize()
    @out = $stdout
    @size = 10
    @bar_char_undone = "_"
    @bar_char_done   = "#"
    @show_percent    = true
    @printend_max_size = 0
  end
  def start(message="")
    out.puts message
    out.print bar_char_undone * size 
    out.flush
  end
  def end(message="")
    progress(100)
    out.print " " + message
    out.puts ""
    out.flush
  end
  def clear()
    out.print "\r"
    line_size = [@printend_max_size, @size].max
    out.print " " * line_size
    out.flush
  end
  def progress(percent,message=nil)
    clear()
    str =""
    str <<  "\r"
    str <<  bar_char_done   * ((percent.to_f/100.to_f)*size).to_i
    str <<  bar_char_undone * (size - ((percent.to_f/100.to_f)*size).to_i)
    str <<  " " + percent.to_s + "%" if show_percent
    str <<  " " + message  if message
    @printend_max_size = str.size if str.size > @printend_max_size
    out.print str
    out.flush
  end
end



if __FILE__ == $0
require 'tmpdir'
require 'find'
require 'pp'
    #Dir.mktmpdir('foo') do |dir|
      #Dir.chdir dir do 
        #Dir.mkdir("src")
        #Dir.mkdir("dst")
        #open("./src/test1.txt", "w+"){|f| 10.times{f.puts("test")}}
        #open("./dst/test2.txt", "w+"){|f| 10.times{f.puts("aaaa")}}
        #rsync = RbSync.new
        #$count = $count+ 1
        #rsync.sync("src","dst",{:update=>true})
        #$count = $count+ 1
        #rsync.sync("dst","src",{:update=>true})
        #p File.mtime("./src/test2.txt")
        ##p FileUtils.cmp("src/test1.txt","dst/test1.txt")
        ##p FileUtils.cmp("src/test2.txt","dst/test2.txt")
        ##p open("./dst/test2.txt", "r").read
        ##p open("./src/test2.txt", "r").read
        #open("./src/test2.txt", "w+"){|f| 10.times{f.puts("bbb")}}
        #p File.mtime("./src/test2.txt")
        #$count = $count+ 1
        #rsync.sync("src","dst",{:update=>true,})
        ##rsync.sync("dst","src",{:update=>true})
        #p open("./dst/test2.txt", "r").read
        #p open("./src/test2.txt", "r").read
        #p FileUtils.cmp("src/test2.txt","dst/test2.txt")
      #end
    #end
  puts :END
end
