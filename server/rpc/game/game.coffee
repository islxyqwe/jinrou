#,type シェアするやつ
Shared=
    game:require '../../../client/code/shared/game.coffee'
    prize:require '../../../client/code/shared/prize.coffee'

cron=require 'cron'

# 浅いコピー
copyObject=(obj)->
    result=Object.create Object.getPrototypeOf obj
    for key in Object.keys(obj)
        result[key]=obj[key]
    result

#内部用
module.exports=
    newGame: (room,ss)->
        game=new Game ss,room
        games[room.id]=game
        M.games.insert game.serialize()
    # 游戏オブジェクトを読み込んで使用可能にする
    ###
    loadDB:(roomid,ss,cb)->
        if games[roomid]
            # 既に読み込んでいる
            cb games[roomid]
            return
        M.games.find({finished:false}).each (err,doc)->
            return unless doc?
            if err?
                console.log err
                throw err
            games[doc.id]=Game.unserialize doc,ss
    ###
    # 参加中のプレイヤー人数（Endless黑暗火锅用）
    endlessPlayersNumber:(roomid)->
        game=games[roomid]
        if game?
            # 强行退出はカウントしない
            return game.players.filter((x)->!x.dead || !x.norevive).length
        else
            return Number.NaN
    # プレイヤーが入室したぞ!
    inlog:(room,player)->
        name="#{player.name}"
        pr=""
        unless room.blind in ["complete","yes"]
            # 匿名模式のときは称号OFF
            player.nowprize?.forEach? (x)->
                if x.type=="prize"
                    prname=Server.prize.prizeName x.value
                    if prname?
                        pr+=prname
                else
                    # 接続
                    pr+=x.value
            if pr
                name="#{Server.prize.prizeQuote pr}#{name}"
        if room.mode=="waiting"
            # 开始前（ふつう）
            log=
                comment:"#{name} 加入了游戏。"
                userid:-1
                name:null
                mode:"system"
            if games[room.id]
                splashlog room.id,games[room.id], log
                # プレイヤーを追加
                newpl=Player.factory "Waiting"
                newpl.setProfile {
                    id:player.userid
                    realid:player.realid
                    name:player.name
                }
                newpl.setTarget null
                games[room.id].players.push newpl
                games[room.id].participants.push newpl
        else if room.mode=="playing" && room.jobrule=="特殊规则.Endless黑暗火锅"
            # Endless黑暗火锅に途中参加
            if games[room.id]
                game=games[room.id]
                log=
                    comment:"#{name} 加入了游戏。"
                    mode:"inlog"
                    to:player.userid
                splashlog room.id,game,log
                # プレイヤーを追加（まだ参加しない系のひと）
                newpl=Player.factory "Watching"
                newpl.setProfile {
                    id:player.userid
                    realid:player.realid
                    name:player.name
                }
                newpl.setTarget null
                # 头像追加
                game.iconcollection[newpl.id]=player.icon
                # playersには追加しない（翌朝追加）
                games[room.id].participants.push newpl
    outlog:(room,player)->
        log=
            comment:"#{player.name} 离开了游戏。"
            userid:-1
            name:null
            mode:"system"
        if games[room.id]
            splashlog room.id,games[room.id], log
            games[room.id].players=games[room.id].players.filter (pl)->pl.realid!=player.realid
            games[room.id].participants=games[room.id].participants.filter (pl)->pl.realid!=player.realid
    kicklog:(room,player)->
        log=
            comment:"#{player.name} 被踢出了游戏。"
            userid:-1
            name:null
            mode:"system"
        console.log "game"+room.id+"存在"
        unless games[room.id]?
            # 检索数据库game是否不存在？
            M.games.findOne {id:room.id}, (err,doc)=>
                if err?
                    console.log err
                    throw err
                unless doc?
                    M.rooms.remove {id:room.id}
                    console.log "由于game不存在，room"+room.id+"被移除"
                    return
                games[roomid]=game=Game.unserialize doc,ss
                ne()
            return
        if games[room.id]
            splashlog room.id,games[room.id], log
            games[room.id].players=games[room.id].players.filter (pl)->pl.realid!=player.realid
            games[room.id].participants=games[room.id].participants.filter (pl)->pl.playerid!=player.realid
    helperlog:(room,player,topl)->
        log=null
        if topl?
            log=
                comment:"#{player.name} 成为了 #{topl.name} 的帮手。"
                userid:-1
                name:null
                mode:"system"
        else
            log=
                comment:"#{player.name} 放弃做帮手了。"
                userid:-1
                name:null
                mode:"system"

        if games[room.id]
            splashlog room.id,games[room.id], log
    deletedlog:(room)->
        log=
            comment:"这个房间已经废弃。"
            userid:-1
            name:null
            mode:"system"
        if games[room.id]
            splashlog room.id,games[room.id], log
    # 状況に応じたチャンネルを割り当てる
    playerchannel:(roomid,session)->
        game=games[roomid]
        unless game?
            return
        player=game.getPlayerReal session.userId
        unless player?
            session.channel.subscribe "room#{roomid}_audience"
            # session.channel.subscribe "room#{roomid}_notwerewolf"
            # session.channel.subscribe "room#{roomid}_notcouple"
            return
        if player.isJobType "GameMaster"
            session.channel.subscribe "room#{roomid}_gamemaster"
            return
        ###
        if player.dead
            session.channel.subscribe "room#{roomid}_heaven"
        if game.rule.heavenview!="view" || !player.dead
            if player.isWerewolf()
                session.channel.subscribe "room#{roomid}_werewolf"
            else
                session.channel.subscribe "room#{roomid}_notwerewolf"
        if game.rule.heavenview!="view" || !player.dead
            if player.type=="Couple"
                session.channel.subscribe "room#{roomid}_couple"
            else
                session.channel.subscribe "room#{roomid}_notcouple"
        if player.type=="Fox"
            session.channel.subscribe "room#{roomid}_fox"
        ###
Server=
    game:
        game:module.exports
        rooms:require './rooms.coffee'
    prize:require '../../prize.coffee'
    oauth:require '../../oauth.coffee'
class Game
    constructor:(@ss,room)->
        # @ss: ss
        if room?
            @id=room.id
            # GMがいる場合
            @gm= if room.gm then room.owner.userid else null
        
        @logs=[]
        @players=[]         # 村人たち
        @participants=[]    # 参加者全て(@playersと同じ内容含む）
        @rule=null
        @finished=false #终了したかどうか
        @day=0  #何日目か(0=準備中)
        @night=false # false:昼 true:夜
        
        @winner=null    # 勝ったチーム名
        @quantum_patterns=[]    # 全部の場合を列挙({(id):{jobtype:"Jobname",dead:Boolean},...})
        # DBには現れない
        @timerid=null
        @voting=false   # 投票犹豫时间
        @timer_start=null   # 残り时间のカウント开始时间（秒）
        @timer_remain=null  # 残り时间全体（秒）
        @timer_mode=null    # タイマーの名字
        @revote_num=0   # 重新投票を行った回数
        
        @werewolf_target=[] # 人狼の襲い先
        @werewolf_target_remain=0   #襲撃先をあと何人设定できるか
        @werewolf_flag=[] # 人狼襲撃に関するフラグ

        @slientexpires=0    # 静かにしてろ！（この时间まで）
        @heavenview=false   # 灵界表示がどうなっているか

        @gamelogs=[]
        @iconcollection={}  #(id):(url)
        # 决定配置（DBに入らないかも・・・）
        @joblist=null
        # 游戏スタートに必要な情報
        @startoptions=null
        @startplayers=null
        @startsupporters=null

        # 希望役职制のときに开始前に职业选择するフェーズ
        @rolerequestingphase=false
        @rolerequesttable={}    # 一览{(id):(jobtype)}
        
        # 投票箱を用意しておく
        @votingbox=new VotingBox this
        ###
        さまざまな出来事
        id: 動作した人
        gamelogs=[
            {id:(id),type:(type/null),target:(id,null),event:(String),flag:(String),day:(Number)},
            {...},
        ###
    # JSON用object化(DB保存用）
    serialize:->
        {
            id:@id
            logs:@logs
            rule:@rule
            players:@players.map (x)->x.serialize()
            # 差分
            additionalParticipants: @participants?.filter((x)=>@players.indexOf(x)<0).map (x)->x.serialize()
            finished:@finished
            day:@day
            night:@night
            winner:@winner
            jobscount:@jobscount
            gamelogs:@gamelogs
            gm:@gm
            iconcollection:@iconcollection
            werewolf_flag:@werewolf_flag
            werewolf_target:@werewolf_target
            werewolf_target_remain:@werewolf_target_remain
            #quantum_patterns:@quantum_patterns
        }
    #DB用をもとにコンストラクト
    @unserialize:(obj,ss)->
        game=new Game ss
        game.id=obj.id
        game.gm=obj.gm
        game.logs=obj.logs
        game.rule=obj.rule
        game.players=obj.players.map (x)->Player.unserialize x
        # 追加する
        if obj.additionalParticipants
            game.participants=game.players.concat obj.additionalParticipants.map (x)->Player.unserialize x
        else
            game.participants=game.players.concat []

        game.finished=obj.finished
        game.day=obj.day
        game.night=obj.night
        game.winner=obj.winner
        game.jobscount=obj.jobscount
        game.gamelogs=obj.gamelogs ? {}
        game.gm=obj.gm
        game.iconcollection=obj.iconcollection ? {}
        game.werewolf_flag=if Array.isArray obj.werewolf_flag
            # 配列ではなく文字列/nullだった時代のあれ
            obj.werewolf_flag
        else if obj.werewolf_flag?
            [obj.werewolf_flag]
        else
            []

        game.werewolf_target=obj.werewolf_target ? []
        game.werewolf_target_remain=obj.werewolf_target_remain ? 0
        # 开始前なら準備中を用意してあげないと！
        if game.day==0
            Server.game.rooms.oneRoomS game.id,(room)->
                if room.error?
                    return
                game.players=[]
                for plobj in room.players
                    newpl=Player.factory "Waiting"
                    newpl.setProfile {
                        id:plobj.userid
                        realid:plobj.realid
                        name:plobj.name
                    }
                    newpl.setTarget null
                    game.players.push newpl
                game.participants=game.players.concat []

        game.quantum_patterns=obj.quantum_patterns ? []
        unless game.finished
            if game.rule
                game.timer()
            if game.day>0
                if !game.night
                    # 昼の場合投票箱をつくる
                    game.votingbox.setCandidates game.players.filter (x)->!x.dead
        game
    # 公開情報
    publicinfo:(obj)->  #obj:选项
        {
            rule:@rule
            finished:@finished
            players:@players.map (x)=>
                r=x.publicinfo()
                r.icon= @iconcollection[x.id] ? null
                    
                if obj?.openjob
                    r.jobname=x.getJobname()
                    #r.option=x.optionString()
                    r.option=""
                    r.originalJobname=x.originalJobname
                    r.winner=x.winner
                unless @rule?.blind=="complete" || (@rule?.blind=="yes" && !@finished)
                    # 公開してもよい
                    r.realid=x.realid
                r
            day:@day
            night:@night
            jobscount:@jobscount
        }
    # IDからプレイヤー
    getPlayer:(id)->
        @players.filter((x)->x.id==id)[0]
    getPlayerReal:(realid)->
        #@players.filter((x)->x.realid==realid)[0] || if @gm && @gm==realid then new GameMaster realid,realid,"游戏管理员"
        @participants.filter((x)->x.realid==realid)[0]
    # DBにセーブ
    save:->
        M.games.update {id:@id},@serialize()
    # gamelogsに追加
    addGamelog:(obj)->
        @gamelogs ?= []
        @gamelogs.push {
            id:obj.id ? null
            type:obj.type ? null
            target:obj.target ? null
            event:obj.event ? null
            flag:obj.flag ? null
            day:@day    # 何気なく日付も追加
        }
        
    setrule:(rule)->@rule=rule
    #成功:null
    #players: 参加者 supporters: 其他
    setplayers:(res)->
        options=@startoptions
        players=@startplayers
        supporters=@startsupporters
        jnumber=0
        joblist=@joblist
        players=players.concat []   #模仿者
        plsl=players.length #実際の参加人数（身代わり含む）
        if @rule.scapegoat=="on"
            plsl++
        @players=[]
        @iconcollection={}
        for job,num of joblist
            #console.log "#{job}:#{num}"
            unless isNaN num
                jnumber+=parseInt num
            if parseInt(num)<0
                res "玩家人数无效（#{job}:#{num})。多次重试可能解决这个错误。"
                return

        if jnumber!=plsl
            # 数が合わない
            res "玩家人数无效 (#{jnumber}/#{plsl}/#{players.length})。多次重试可能解决这个错误。"
            return

        # 名字と数を出したやつ
        @jobscount={}
        unless options.yaminabe_hidejobs    # 公開モード
            for job,num of joblist
                continue unless num>0
                testpl=new jobs[job]
                @jobscount[job]=
                    name:testpl.jobname
                    number:num

        # 盗賊の処理
        thief_jobs=[]
        if joblist.Thief>0
            # 小偷一人につき2回抜く
            for i in [0...(joblist.Thief*2)]
                # 1つ抜く
                keys=[]
                # 数に比例した职业一览を作る
                for job,num of joblist
                    unless job in Shared.game.nonhumans
                        for j in [0...num]
                            keys.push job
                keys=shuffle keys

                until keys.length==0 || joblist[keys[0]]>0
                    # 抜けない
                    keys.splice 0,1
                # これは抜ける
                if keys.length==0
                    # もう無い
                    res "小偷处理失败"
                    return
                thief_jobs.push keys[0]
                joblist[keys[0]]--
                # 代わりに村人1つ入れる
                joblist.Human ?= 0
                joblist.Human++




        # まず替身君を決めてあげる
        if @rule.scapegoat=="on"
            # 人狼、妖狼にはならない
            i=0 # 無限ループ防止
            nogoat=[]   #身代わりがならない职业
            if @rule.safety!="free"
                nogoat=nogoat.concat Shared.game.nonhumans  #人外は除く
            if @rule.safety=="full"
                # 危ない
                nogoat=nogoat.concat ["QueenSpectator","Spy2","Poisoner","Cat","BloodyMary","Noble"]
            jobss=[]
            for job in Object.keys jobs
                continue if !joblist[job] || (job in nogoat)
                j=0
                while j<joblist[job]
                    jobss.push job
                    j++
            while ++i<100
                r=Math.floor Math.random()*jobss.length
                continue unless joblist[jobss[r]]>0
                # 职业はjobss[r]
                newpl=Player.factory jobss[r]   #替身君
                newpl.setProfile {
                    id:"替身君"
                    realid:"替身君"
                    name:"替身君"
                }
                newpl.scapegoat=true
                @players.push newpl
                joblist[jobss[r]]--
                break
            if @players.length==0
                # 決まっていない
                res "角色分配失败"
                return
            
        if @rule.rolerequest=="on"
            # 希望役职制ありの場合はまず希望を優先してあげる
            for job,num of joblist
                while num>0
                    # 候補を集める
                    conpls=players.filter (x)=>
                        @rolerequesttable[x.userid]==job
                    if conpls.length==0
                        # もうない
                        break
                    # 候補がいたので決めてあげる
                    r=Math.floor Math.random()*conpls.length
                    pl=conpls[r]
                    players=players.filter (x)->x!=pl
                    newpl=Player.factory job
                    newpl.setProfile {
                        id:pl.userid
                        realid:pl.realid
                        name:pl.name
                    }
                    @players.push newpl
                    if pl.icon
                        @iconcollection[newpl.id]=pl.icon
                    if pl.scapegoat
                        # 替身君
                        newpl.scapegoat=true
                    num--
                # 残った分は戻す
                joblist[job]=num


        # ひとり決める
        for job,num of joblist
            i=0
            while i++<num
                r=Math.floor Math.random()*players.length
                pl=players[r]
                newpl=Player.factory job
                newpl.setProfile {
                    id:pl.userid
                    realid:pl.realid
                    name:pl.name
                }
                @players.push newpl
                players.splice r,1
                if pl.icon
                    @iconcollection[newpl.id]=pl.icon
                if pl.scapegoat
                    # 替身君
                    newpl.scapegoat=true
        if joblist.Thief>0
            # 小偷がいる場合
            thieves=@players.filter (x)->x.isJobType "Thief"
            for pl in thieves
                pl.setFlag JSON.stringify thief_jobs.splice 0,2

        # サブ系
        if options.decider
            # 决定者を作る
            r=Math.floor Math.random()*@players.length
            pl=@players[r]
        
            newpl=Player.factory null,pl,null,Decider   # 酒鬼
            pl.transProfile newpl
            pl.transform @,newpl,true,true
        if options.authority
            # 权力者を作る
            r=Math.floor Math.random()*@players.length
            pl=@players[r]
        
            newpl=Player.factory null,pl,null,Authority # 酒鬼
            pl.transProfile newpl
            pl.transform @,newpl,true,true
        
        if @rule.wolfminion
            # 狼的仆从がいる場合、子分决定者を作る
            wolves=@players.filter((x)->x.isWerewolf())
            if wolves.length>0
                r=Math.floor Math.random()*wolves.length
                pl=wolves[r]
                
                sub=Player.factory "MinionSelector" # 子分决定者
                pl.transProfile sub
                
                newpl=Player.factory null,pl,sub,Complex
                pl.transProfile newpl
                pl.transform @,newpl,true
        if @rule.drunk
            # 酒鬼がいる場合
            nonvillagers= @players.filter (x)->!x.isJobType "Human"
            
            if nonvillagers.length>0
            
                r=Math.floor Math.random()*nonvillagers.length
                pl=nonvillagers[r]
            
                newpl=Player.factory null,pl,null,Drunk # 酒鬼
                pl.transProfile newpl
                pl.transform @,newpl,true,true

            
        # プレイヤーシャッフル
        @players=shuffle @players
        @participants=@players.concat []    # 模仿者
        # ここでプレイヤー以外の処理をする
        for pl in supporters
            if pl.mode=="gm"
                # 游戏管理员だ
                gm=Player.factory "GameMaster"
                gm.setProfile {
                    id:pl.userid
                    realid:pl.realid
                    name:pl.name
                }
                @participants.push gm
            else if result=pl.mode.match /^helper_(.+)$/
                # 帮手だ
                ppl=@players.filter((x)->x.id==result[1])[0]
                unless ppl?
                    res "#{pl.name} 的帮助对象已不存在。"
                    return
                helper=Player.factory "Helper"
                helper.setProfile {
                    id:pl.realid
                    realid:pl.realid
                    name:pl.name
                }
                helper.setFlag ppl.id  # ヘルプ先
                @participants.push helper
            #@participants.push new GameMaster pl.userid,pl.realid,pl.name
        
        # 量子人狼の場合はここで可能性リストを作る
        if @rule.jobrule=="特殊规则.量子人狼"
            # パターンを初期化（最初は全パターン）
            quats=[]    # のとみquantum_patterns
            pattern_no=0    # とばす
            # 职业を列挙した配列をつくる
            jobname_list=[]
            for job of jobs
                i=@rule.quantum_joblist[job]
                if i>0
                    jobname_list.push {
                        type:job,
                        number:i
                    }
            # 人狼用
            i=1
            while @rule.quantum_joblist["Werewolf#{i}"]>0
                jobname_list.push {
                    type:"Werewolf#{i}"
                    number:@rule.quantum_joblist["Werewolf#{i}"]
                }
                i++
            # プレイヤーIDを列挙した配列もつくる
            playerid_list=@players.map (pl)->pl.id
            # 0,1,...,(n-1)の中からkコ選んだ組み合わせを返す関数
            combi=(n,k)->
                `var i;`
                if k<=0
                    return [[]]
                if n<=k #n<kのときはないけど・・・
                    return [[0...n]] # 0からn-1まで
                resulty=[]
                for i in [0..(n-k)] # 0 <= i <= n-k
                    for x in combi n-i-1,k-1
                        resulty.push [i].concat x.map (y)->y+i+1
                resulty

            # 職をひとつ処理
            makeonejob=(joblist,plids)->
                cont=joblist[0]
                unless cont?
                    return [[]]
                # 決めて抜く
                coms=combi plids.length,cont.number
                # その番号のを
                resulty2=[]
                for pat in coms #pat: 1つのパターン
                    bas=[]
                    pll=plids.concat []
                    i=0
                    for num in pat
                        bas.push {
                            id:pll[num-i]
                            job:cont.type
                        }
                        pll.splice num-i,1  # 抜く
                        i+=1
                    resulty2=resulty2.concat makeonejob(joblist.slice(1),pll).map (arr)->
                        bas.concat arr
                resulty2

            jobsobj=makeonejob jobname_list,playerid_list
            # パターンを作る
            for arr in jobsobj
                obj={}
                for o in arr
                    result=o.job.match /^Werewolf(\d+)$/
                    if result
                        obj[o.id]={
                            jobtype:"Werewolf"
                            rank:+result[1] # 狼の序列
                            dead:false
                        }
                    else
                        obj[o.id]={
                            jobtype:o.job
                            dead:false
                        }
                quats.push obj
            # できた
            @quantum_patterns=quats
            if @rule.quantumwerewolf_table=="anonymous"
                # 概率表は数字で表示するので番号をつけてあげる
                for pl,i in shuffle @players.concat []
                    pl.setFlag JSON.stringify {
                        number:i+1
                    }

        res null
    #======== 游戏進行の処理
    #次のターンに進む
    nextturn:->
        clearTimeout @timerid
        if @day<=0
            # はじまる前
            @day=1
            @night=true
        else if @night==true
            @day++
            @night=false
        else
            @night=true

        log=
            mode:"nextturn"
            day:@day
            night:@night
            userid:-1
            name:null
            comment:"第#{@day}天的#{if @night then '夜晚' else '白天'}到来了。"
        splashlog @id,this,log

        #死体処理
        @bury(if @night then "night" else "day")

        if @rule.jobrule=="特殊规则.量子人狼"
            # 量子人狼
            # 全员の確率を出してあげるよーーーーー
            # 確率テーブルを
            probability_table={}
            numberref_table={}
            dead_flg=true
            while dead_flg
                dead_flg=false
                for x in @players
                    if x.dead
                        continue
                    dead=0
                    for obj in @quantum_patterns
                        if obj[x.id].dead==true
                            dead++
                    if dead==@quantum_patterns.length
                        # 死んだ!!!!!!!!!!!!!!!!!
                        x.die this,"werewolf"
                        dead_flg=true
            for x in @players
                count=
                    Human:0
                    Diviner:0
                    Werewolf:0
                    dead:0
                for obj in @quantum_patterns
                    count[obj[x.id].jobtype]++
                    if obj[x.id].dead==true
                        count.dead++
                sum=count.Human+count.Diviner+count.Werewolf
                pflag=JSON.parse x.flag
                if sum==0
                    # 世界が崩壊した
                    x.setFlag JSON.stringify {
                        number:pflag?.number
                        Human:0
                        Diviner:0
                        Werewolf:0
                        dead:0
                    }
                    # ログ用
                    probability_table[x.id]={
                        name:x.name
                        Human:0
                        Werewolf:0
                    }
                    if @rule.quantumwerewolf_dead=="on"
                        #死亡確率も
                        probability_table[x.id].dead=0
                    if @rule.quantumwerewolf_diviner=="on"
                        # 占卜师の確率も
                        probability_table[x.id].Diviner=0
                else
                    x.setFlag JSON.stringify {
                        number:pflag?.number
                        Human:count.Human/sum
                        Diviner:count.Diviner/sum
                        Werewolf:count.Werewolf/sum
                        dead:count.dead/sum
                    }
                    # ログ用
                    if @rule.quantumwerewolf_diviner=="on"
                        probability_table[x.id]={
                            name:x.name
                            Human:count.Human/sum
                            Diviner:count.Diviner/sum
                            Werewolf:count.Werewolf/sum
                        }
                    else
                        probability_table[x.id]={
                            name:x.name
                            Human:(count.Human+count.Diviner)/sum
                            Werewolf:count.Werewolf/sum
                        }
                    if @rule.quantumwerewolf_dead!="no" || count.dead==sum
                        # 死亡率も
                        probability_table[x.id].dead=count.dead/sum
                if @rule.quantumwerewolf_table=="anonymous"
                    # 番号を表示
                    numberref_table[pflag.number]=x
                    probability_table[x.id].name="玩家 #{pflag.number}"
            if @rule.quantumwerewolf_table=="anonymous"
                # ソートしなおしてあげて痕跡を消す
                probability_table=((probability_table,numberref_table)->
                    result={}
                    i=1
                    x=null
                    while x=numberref_table[i]
                        result["_$_player#{i}"]=probability_table[x.id]
                        i++
                    result
                )(probability_table,numberref_table)
            # ログを出す
            log=
                mode:"probability_table"
                probability_table:probability_table
            splashlog @id,this,log
            # もう一回死体処理
            @bury(if @night then "night" else "day")
    
            return if @judge()

        @voting=false
        if @night
            # job数据を作る
            # 人狼の襲い先
            @werewolf_target=[]
            unless @day==1 && @rule.scapegoat!="off"
                @werewolf_target_remain=1
            else if @rule.scapegoat=="on"
                # 誰が襲ったかはランダム
                onewolf=@players.filter (x)->x.isWerewolf()
                if onewolf.length>0
                    r=Math.floor Math.random()*onewolf.length
                    @werewolf_target.push {
                        from:onewolf[r].id
                        to:"替身君"    # みがわり
                    }
                    console.log "aoo!",onewolf[r].id
                @werewolf_target_remain=0
            else
                # 誰も襲わない
                @werewolf_target_remain=0
            
            werewolf_flag_result=[]
            for fl in @werewolf_flag
                if fl=="Diseased"
                    # 病人フラグが立っている（今日は襲撃できない
                    @werewolf_target_remain=0
                    log=
                        mode:"wolfskill"
                        comment:"人狼们染病了。今天无法出击。"
                    splashlog @id,this,log
                else if fl=="WolfCub"
                    # 狼之子フラグが立っている（2回襲撃できる）
                    @werewolf_target_remain=2
                    log=
                        mode:"wolfskill"
                        comment:"为狼之子复仇吧，今天可以袭击两个人。"
                    splashlog @id,this,log
                else
                    werewolf_flag_result.push fl
            @werewolf_flag=werewolf_flag_result
            
            alives=[]
            deads=[]
            for player in @players
                if player.dead
                    deads.push player.id
                else
                    alives.push player.id
            for i in (shuffle [0...(@players.length)])
                player=@players[i]
                if player.id in alives
                    player.sunset this
                else
                    player.deadsunset this
        else
            # 誤爆防止
            @werewolf_target_remain=0
            # 処理
            if @rule.deathnote
                # 死亡笔记採用
                alives=@players.filter (x)->!x.dead
                if alives.length>0
                    r=Math.floor Math.random()*alives.length
                    pl=alives[r]
                    sub=Player.factory "Light"  # 副を作る
                    pl.transProfile sub
                    sub.sunset this
                    newpl=Player.factory null,pl,sub,Complex
                    pl.transProfile newpl
                    @players.forEach (x,i)=>    # 入れ替え
                        if x.id==newpl.id
                            @players[i]=newpl
                        else
                            x
            # Endless黑暗火锅用途中参加処理
            if @rule.jobrule=="特殊规则.Endless黑暗火锅"
                exceptions=["MinionSelector","Thief","GameMaster","Helper","QuantumPlayer","Waiting","Watching"]
                jobnames=Object.keys(jobs).filter (name)->!(name in exceptions)
                pcs=@participants.concat []
                join_count=0
                for player in pcs
                    if player.isJobType "Watching"
                        # 参加待機のひとだ
                        if !@players.some((p)->p.id==player.id)
                            # 本参加ではないのでOK
                            # 职业をランダムに决定
                            newjob=jobnames[Math.floor Math.random()*jobnames.length]
                            newpl=Player.factory newjob
                            player.transProfile newpl
                            player.transferData newpl
                            # 观战者を除去
                            @participants=@participants.filter (x)->x!=player
                            # プレイヤーとして追加
                            @players.push newpl
                            @participants.push newpl
                            # ログをだす
                            log=
                                mode:"system"
                                comment:"#{newpl.name} 加入了游戏。"
                            splashlog @id,@,log
                            join_count++
                # たまに転生
                deads=shuffle @players.filter (x)->x.dead && !x.norevive
                # 転生確率
                # 1人の転生確率をpとすると死者n人に対して転生人数の期待値はpn人。
                # 1ターンに2人しぬとしてp(n+2)=2とおくとp=2/(n+2) 。
                # 少し減らして人数を減少に持って行く
                p = 2/(deads.length+3)
                # 死者全员に対して転生判定
                for pl in deads
                    if Math.random()<p
                        # でも参加者がいたら蘇生のかわりに
                        if join_count>0 && Math.random()>p
                            join_count--
                            continue
                        newjob=jobnames[Math.floor Math.random()*jobnames.length]
                        newpl=Player.factory newjob
                        pl.transProfile newpl
                        pl.transferData newpl
                        # 蘇生
                        newpl.setDead false
                        pl.transform @,newpl,true
                        log=
                            mode:"system"
                            comment:"#{pl.name} 转生了。"
                        splashlog @id,@,log
                        @ss.publish.user newpl.id,"refresh",{id:@id}


            # 投票リセット処理
            @votingbox.init()
            @votingbox.setCandidates @players.filter (x)->!x.dead
            alives=[]
            deads=[]
            for player in @players
                if player.dead
                    deads.push player.id
                else
                    alives.push player.id
            for i in (shuffle [0...(@players.length)])
                player=@players[i]
                if player.id in alives
                    player.sunrise this
                else
                    player.deadsunrise this
            for pl in @players
                if !pl.dead
                    pl.votestart this
            @revote_num=0   # 重新投票の回数は0にリセット

        #死体処理
        @bury "other"
        return if @judge()
        @splashjobinfo()
        if @night
            @checkjobs()
        else
            # 昼は15秒规则があるかも
            if @rule.silentrule>0
                @silentexpires=Date.now()+@rule.silentrule*1000 # これまでは黙っていよう！
        @save()
        @timer()
    #全员に状況更新 pls:状況更新したい人を指定する場合の配列
    splashjobinfo:(pls)->
        unless pls?
            # プレイヤー以外にも
            @ss.publish.channel "room#{@id}_audience","getjob",makejobinfo this,null
            # GMにも
            if @gm?
                @ss.publish.channel "room#{@id}_gamemaster","getjob",makejobinfo this,@getPlayerReal @gm
            pls=@participants

        pls.forEach (x)=>
            @ss.publish.user x.realid,"getjob",makejobinfo this,x
    #全员寝たかチェック 寝たなら処理してtrue
    #timeoutがtrueならば时间切れなので时间でも待たない
    checkjobs:(timeout)->
        if @day==0
            # 开始前（希望役职制）
            if timeout || @players.every((x)=>@rolerequesttable[x.id]?)
                # 全员できたぞ
                @setplayers (result)=>
                    unless result?
                        @rolerequestingphase=false
                        @nextturn()
                        @ss.publish.channel "room#{@id}","refresh",{id:@id}
                true
            else
                false

        else if @players.every( (x)=>x.dead || x.sleeping(@))
            if @voting || timeout || !@rule.night || @rule.waitingnight!="wait" #夜に时间がある場合は待ってあげる
                @midnight()
                @nextturn()
                true
            else
                false
        else
            false

    #夜の能力を処理する
    midnight:->
        alives=[]
        deads=[]
        for player in @players
            if player.dead
                deads.push player.id
            else
                alives.push player.id
        for i in (shuffle [0...(@players.length)])
            player=@players[i]
            if player.id in alives
                player.midnight this
            else
                player.deadnight this
            
        # 狼の処理
        for target in @werewolf_target
            t=@getPlayer target.to
            continue unless t?
            # 噛まれた
            t.addGamelog this,"bitten"
            if @rule.noticebitten=="notice" || t.isJobType "Devil"
                log=
                    mode:"skill"
                    to:t.id
                    comment:"#{t.name} 被人狼袭击了。"
                splashlog @id,this,log
            if !t.dead
                # 死んだ
                t.die this,"werewolf",target.from
            # 逃亡者を探す
            runners=@players.filter (x)=>!x.dead && x.isJobType("Fugitive") && x.target==target.to
            runners.forEach (x)=>
                x.die this,"werewolf2",target.from   # その家に逃げていたら逃亡者も死ぬ

            if !t.dead
                # 死んでない
                flg_flg=false  # なにかのフラグ
                for fl in @werewolf_flag
                    res = fl.match /^ToughWolf_(.+)$/
                    if res?
                        # 硬汉人狼がすごい
                        tw = @getPlayer res[1]
                        t=@getPlayer target.to
                        if t?
                            t.setDead true,"werewolf2"
                            t.dying this,"werewolf2",tw.id
                            flg_flg=true
                            if tw?
                                unless tw.dead
                                    tw.die this,"werewolf2"
                                    tw.addGamelog this,"toughwolfKilled",t.type,t.id
                            break
                unless flg_flg
                    # 一途は発動しなかった
                    for fl in @werewolf_flag
                        res = fl.match /^GreedyWolf_(.+)$/
                        if res?
                            # 欲張り狼がやられた!
                            gw = @getPlayer res[1]
                            if gw?
                                gw.die this,"werewolf2"
                                gw.addGamelog this,"greedyKilled",t.type,t.id
                                # 以降は襲撃できない
                                flg_flg=true
                                break
                    if flg_flg
                        # 欲張りのあれで襲撃终了
                        break
        @werewolf_flag=@werewolf_flag.filter (fl)->
            # こいつらは1夜限り
            return !(/^(?:GreedyWolf|ToughWolf)_/.test fl)

    # 死んだ人を処理する type: タイミング
    # type: "day": 夜が明けたタイミング "night": 处刑後 "other":其他(ターン変わり時の能力で死んだやつなど）
    bury:(type)->

        @votingbox.candidates = @votingbox.candidates.filter (x)->!x.dead
        deads=[]
        loop
            deads=@players.filter (x)->x.dead && x.found
            deadsl=deads.length
            alives=@players.filter (x)->!x.dead
            alives.forEach (x)=>
                x.beforebury this,type
            deads=@players.filter (x)->x.dead && x.found
            if deadsl>=deads.length
                # もう新しく死んだ人はいない
                break
        # 灵界で职业表示してよいかどうか更新
        switch @rule.heavenview
            when "view"
                @heavenview=true
            when "norevive"
                @heavenview=!@players.some((x)->x.isReviver())
            else
                @heavenview=false
        deads=shuffle deads # 順番バラバラ
        deads.forEach (x)=>
            situation=switch x.found
                #死因
                when "werewolf","werewolf2","poison","hinamizawa","vampire","vampire2","witch","dog","trap","marycurse","psycho"
                    "不成样子的尸体被发现了"
                when "curse"    # 呪殺
                    if @rule.deadfox=="obvious"
                        "被咒杀了"
                    else
                        "不成样子的尸体被发现了"
                when "punish"
                    "被处刑了"
                when "spygone"
                    "离开了村子"
                when "deathnote"
                    "的尸体被发现了"
                when "foxsuicide"
                    "追随着妖狐自尽了"
                when "friendsuicide"
                    "追随着恋人自尽了"
                when "infirm"
                    "衰老而死了"
                when "gmpunish"
                    "被GM处死了"
                when "gone-norevive"
                    "强行退出了。"
                when "gone-day"
                    "因为没有及时投票猝死了。猝死是十分令人困扰的行为，请务必不要再犯。"
                when "gone-night"
                    "因为没有及时使用夜间技能猝死了。猝死是十分令人困扰的行为，请务必不要再犯。"
                else
                    "死了"
            log=
                mode:"system"
                comment:"#{x.name} #{situation}"
            splashlog @id,this,log
            ###
            if x.found=="punish"
                # 处刑→灵能
                @players.forEach (y)=>
                    if y.type=="Psychic"
                        # 灵能
                        y.results.push x
            ###
            @addGamelog {   # 死んだときと死因を記録
                id:x.id
                type:x.type
                event:"found"
                flag:x.found
            }
            x.setDead x.dead,"" #発見されました
            @ss.publish.user x.realid,"refresh",{id:@id}
            if @rule.will=="die" && x.will
                # 死んだら遗言発表
                log=
                    mode:"will"
                    name:x.name
                    comment:x.will
                splashlog @id,this,log
        deads.length
                
    # 投票終わりチェック
    # 返り値意味ないんじゃないの?
    execute:->
        return false unless @votingbox.isVoteAllFinished()
        [mode,player,tos,table]=@votingbox.check()
        if mode=="novote"
            # 誰も投票していない・・・
            @revote_num=Infinity
            @judge()
            return false
        # 投票结果
        log=
            mode:"voteresult"
            voteresult:table
            tos:tos
        splashlog @id,this,log

        if mode=="runoff"
            # 重新投票になった
            @dorevote "runoff"
            return false
        else if mode=="revote"
            # 重新投票になった
            @dorevote "revote"
            return false
        else if mode=="punish"
            # 投票
            # 结果が出た 死んだ!
            # だれが投票したか調べる
            follower=table.filter((obj)-> obj.voteto==player.id).map (obj)->obj.id
            player.die this,"punish",follower
            
            if player.dead && @rule.GMpsychic=="on"
                # GM灵能
                log=
                    mode:"system"
                    comment:"根据灵能的结论，被处刑的 #{player.name} 是 #{player.psychicResult}。"
                splashlog @id,this,log
                
            @votingbox.remains--
            if @votingbox.remains>0
                # もっと殺したい!!!!!!!!!
                @bury "other"
                return false if @judge()

                log=
                    mode:"system"
                    comment:"今天还有#{@votingbox.remains}人将被处刑。请继续投票。"
                splashlog @id,this,log

                # 再び投票する処理(下と同じ… なんとかならないか?)
                @votingbox.start()
                @players.forEach (player)=>
                    return if player.dead
                    player.votestart this
                    @ss.publish.channel "room#{@id}","voteform",true
                    @splashjobinfo()
                if @voting
                    # 投票犹豫の場合初期化
                    clearTimeout @timerid
                    @timer()
                return false
            @nextturn()
        return true
    # 重新投票
    dorevote:(mode)->
        # mode: "runoff" - 决胜投票による重新投票 "revote" - 同数による重新投票 "gone" - 突然死による重新投票
        if mode!="runoff"
            @revote_num++
        if @revote_num>=4   # 4回重新投票
            @judge()
            return
        remains=4-@revote_num
        if mode=="runoff"
            log=
                mode:"system"
                comment:"决胜投票。"
        else
            log=
                mode:"system"
                comment:"重新投票。"
            if isFinite remains
                log.comment += "如果在接下来的#{remains}轮投票中无法达成一致，本场游戏将以平局处理。"
        splashlog @id,this,log
        @votingbox.start()
        @players.forEach (player)=>
            return if player.dead
            player.votestart this
        @ss.publish.channel "room#{@id}","voteform",true
        @splashjobinfo()
        if @voting
            # 投票犹豫の場合初期化
            clearTimeout @timerid
            @timer()
    
    # 勝敗决定
    judge:->
        aliveps=@players.filter (x)->!x.dead    # 生きている人を集める
        # 数える
        alives=aliveps.length
        humans=@players.filter((x)->!x.dead && !x.isFox() && x.isHuman()).length
        wolves=@players.filter((x)->!x.dead && !x.isFox() && x.isWerewolf()).length
        vampires=@players.filter((x)->!x.dead && !x.isFox() && x.isVampire()).length

        team=null
        friends_count=null

        # 量子人狼のときは特殊ルーチン
        if @rule.jobrule=="特殊规则.量子人狼"
            assured_wolf=
                alive:0
                dead:0
            total_wolf=0
            obj=@quantum_patterns[0]
            if obj?
                for key,value of obj
                    if value.jobtype=="Werewolf"
                        total_wolf++
                for x in @players
                    unless x.flag
                        # まだだった・・・
                        break
                    flag=JSON.parse x.flag
                    if flag.Werewolf==1
                        # うわあああ絶対人狼だ!!!!!!!!!!
                        if flag.dead==1
                            assured_wolf.dead++
                        else if flag.dead==0
                            assured_wolf.alive++
                if alives<=assured_wolf.alive*2
                    # あーーーーーーー
                    team="Werewolf"
                else if assured_wolf.dead==total_wolf
                    # 全滅した
                    team="Human"
            else
                # もうひとつもないんだ・・・
                log=
                    mode:"system"
                    comment:"在世界崩坏的今天，概率的定义已经变得没有意义了。"
                splashlog @id,this,log
                team="Draw"
        else
        
            if alives==0
                # 全滅
                team="Draw"
            else if wolves==0 && vampires==0
                # 村人胜利
                team="Human"
            else if humans<=wolves && vampires==0
                # 人狼胜利
                team="Werewolf"
            else if humans<=vampires && wolves==0
                # 吸血鬼胜利
                team="Vampire"
                
            if team=="Werewolf" && wolves==1
                # 一匹狼判定
                lw=aliveps.filter((x)->x.isWerewolf())[0]
                if lw?.isJobType "LoneWolf"
                    team="LoneWolf"
                
            if team?
                # 妖狐判定
                if @players.some((x)->!x.dead && x.isFox())
                    team="Fox"
                # 恋人判定
                if @players.some((x)->x.isFriend())
                    # 终了時に恋人生存
                    friends=@players.filter (x)->x.isFriend() && !x.dead
                    gid=0
                    friends_count=0
                    friends_table={}
                    for pl in friends
                        unless friends_table[pl.id]?
                            pt=pl.getPartner()
                            unless friends_table[pt]?
                                friends_count++
                                gid++
                                friends_table[pl.id]=gid
                                friends_table[pt]=gid
                            else
                                # 合併
                                friends_table[pl.id]=friends_table[pt]
                        else
                            unless friends_table[pt]?
                                friends_table[pt]=friends_table[pl.id]
                            else if friends_table[pt]!=friends_table[pl.id]
                                # 食い違っている
                                c=Math.min friends_table[pt],friends_table[pl.id]
                                d=Math.max friends_table[pt],friends_table[pl.id]
                                for key,value of friends_table
                                    if value==d
                                        friends_table[key]=c
                                # グループが合併した
                                friends_count--


                    if friends_count==1
                        # 1組しかいない
                        if @rule.friendsjudge=="alive"
                            team="Friend"
                        else if friends.length==alives
                            team="Friend"
                    else if friends_count>1
                        if alives==friends.length
                            team="Friend"
                        else
                            # 恋人バトル
                            team=null
            # カルト判定
            if alives>0 && aliveps.every((x)->x.isCult() || x.isJobType("CultLeader") && x.team=="Cult" )
                # 全员信者
                team="Cult"
            # 恶魔判定
            if @players.some((x)->x.type=="Devil" && x.flag=="winner" && x.team=="Devil")
                team="Devil"

        if @revote_num>=4 && !team?
            # 重新投票多すぎ
            team="Draw" # 平局
            
        if team?
            # 勝敗决定
            @finished=true
            @winner=team
            if team!="Draw"
                @players.forEach (x)=>
                    iswin=x.isWinner this,team
                    if @rule.losemode
                        # 败北村（負けたら勝ち）
                        if iswin==true
                            iswin=false
                        else if iswin==false
                            iswin=true
                    # ただし突然死したら負け
                    if @gamelogs.some((log)->
                        log.id==x.id && log.event=="found" && log.flag in ["gone-day","gone-night","gone-norevive"]
                    )
                        iswin=false
                    x.setWinner iswin   #胜利か
                    # ユーザー情報
                    if x.winner
                        M.users.update {userid:x.realid},{$push: {win:@id}}
                    else
                        M.users.update {userid:x.realid},{$push: {lose:@id}}
            log=
                mode:"nextturn"
                finished:true
            resultstring=null#结果
            teamstring=null #阵营
            [resultstring,teamstring]=switch team
                when "Human"
                    if alives>0 && aliveps.every((x)->x.isJobType "Neet")
                        ["村子变成了NEET的乐园。","村人胜利"]
                    else
                        ["村子里的人狼已经被赶尽杀绝。","村人胜利"]
                when "Werewolf"
                    ["人狼吃掉了最后一个村民，向着下一个住满了猎物的村庄前进了…","人狼胜利"]
                when "Fox"
                    ["村子成了妖狐的玩物。","妖狐胜利"]
                when "Devil"
                    ["村子成了恶魔的玩物。","恶魔胜利"]
                when "Friend"
                    if friends_count>1
                        # みんなで胜利（珍しい）
                        ["村子从此处于恋人的支配之下。","恋人胜利"]
                    else
                        friends=@players.filter (x)->x.isFriend()
                        if friends.length==2 && friends.some((x)->x.isJobType "Noble") && friends.some((x)->x.isJobType "Slave")
                            ["在两人跨越世俗禁忌的爱情面前，所有阻碍都无法与之匹敌。","恋人胜利"]
                        else
                            ["在#{@players.filter((x)->x.isFriend() && !x.dead).length}人爱的力量面前，所有阻碍都无法与之匹敌。","恋人胜利"]
                when "Cult"
                    ["村子被教会支配了。","邪教胜利"]
                when "Vampire"
                    ["吸血鬼饮尽了最后一个村民的鲜血，向着下一个住满了猎物的村庄前进了…","吸血鬼阵营胜利"]
                when "LoneWolf"
                    ["人狼吃掉了最后一个村民，向着下一个住满了猎物的村庄前进了…","一匹狼胜利"]
                when "Draw"
                    ["平局。",""]
            log.comment="#{if teamstring then "【#{teamstring}】" else ""}#{resultstring}"
            splashlog @id,this,log
            
            
            # 房间を终了状态にする
            M.rooms.update {id:@id},{$set:{mode:"end"}}
            @ss.publish.channel "room#{@id}","refresh",{id:@id}
            @save()
            @prize_check()
            clearTimeout @timerid
            

            # 向房间成员通报猝死统计
            norevivers=@players.filter((x)->x.norevive)
            if norevivers.length
                message = 
                    id:@id
                    userlist:[]
                    time:parseInt(60/@players.length)
                for pl in norevivers
                    message.userlist.push {"userid":pl.realid,"name":pl.name}
                ownerID=M.rooms.findOne {id:@id},(err,doc)->
                    return unless doc?
                    doc.owner.userid
                console.log("ownerID:"+ownerID)
                @ss.publish.channel "room#{@id}",'punishalert',message


            # DBからとってきて告知ツイート
            M.rooms.findOne {id:@id},(err,doc)->
                return unless doc?
                tweet doc.id,"「#{doc.name}」的结果: #{log.comment} #月下人狼"
            
            return true
        else
            return false
    timer:->
        return if @finished
        func=null
        time=null
        mode=null   # なんのカウントか
        timeout= =>
            # 残り时间を知らせるぞ!
            @timer_start=parseInt Date.now()/1000
            @timer_remain=time
            @timer_mode=mode
            @ss.publish.channel "room#{@id}","time",{time:time, mode:mode}
            if time>30
                @timerid=setTimeout timeout,30000
                time-=30
            else if time>0
                @timerid=setTimeout timeout,time*1000
                time=0
            else
                # 时间切れ
                func()
        if @rolerequestingphase
            # 希望役职制
            time=60
            mode="希望选择"
            func= =>
                # 強制开始
                @checkjobs true
        else if @night && !@voting
            # 夜
            time=@rule.night
            mode="夜"
            return unless time
            func= =>
                # ね な い こ だ れ だ
                unless @checkjobs true
                    if @rule.remain
                        # 犹豫时间があるよ
                        @voting=true
                        @timer()
                    else
                        @players.forEach (x)=>
                            return if x.dead || x.sleeping(@)
                            x.die this,"gone-night" # 突然死
                            x.setNorevive true
                            # 突然死記録
                            M.users.update {userid:x.realid},{$push:{gone:@id}}
                        @bury("other")
                        @checkjobs true
                else
                    return
        else if @night
            # 夜の犹豫
            time=@rule.remain
            mode="犹豫"
            func= =>
                # ね な い こ だ れ だ
                @players.forEach (x)=>
                    return if x.dead || x.sleeping(@)
                    x.die this,"gone-night" # 突然死
                    x.setNorevive true
                    # 突然死記録
                    M.users.update {userid:x.realid},{$push:{gone:@id}}
                @bury("other")
                @checkjobs true
        else if !@voting
            # 昼
            time=@rule.day
            mode="昼"
            return unless time
            func= =>
                unless @execute()
                    if @rule.remain
                        # 犹豫があるよ
                        @voting=true
                        log=
                            mode:"system"
                            comment:"白天的讨论时间到此结束。请投票决定要处死的人。"
                        splashlog @id,this,log
                        @timer()
                    else
                        # 突然死
                        revoting=false
                        @players.forEach (x)=>
                            return if x.dead || x.voted(this,@votingbox)
                            x.die this,"gone-day"
                            x.setNorevive true
                            revoting=true
                        @bury("other")
                        @judge()
                        if revoting
                            @dorevote "gone"
                        else
                            @execute()
                else
                    return
        else
            # 犹豫时间も過ぎたよ!
            time=@rule.remain
            mode="犹豫"
            func= =>
                unless @execute()
                    revoting=false
                    @players.forEach (x)=>
                        return if x.dead || x.voted(this,@votingbox)
                        x.die this,"gone-day"
                        x.setNorevive true
                        revoting=true
                    @bury("other")
                    @judge()
                    if revoting
                        @dorevote "gone"
                    else
                        @execute()
                else
                    return
        timeout()
    # プレイヤーごとに　見せてもよいログをリストにする
    makelogs:(player)->
        @logs.map (x)=>
            if islogOK this,player,x
                x
            else
                # 見られなかったけど見たい人用
                if x.mode=="werewolf" && @rule.wolfsound=="aloud"
                    {
                        mode: "werewolf"
                        name: "狼的远吠"
                        comment: "嗷呜・・・"
                        time: x.time
                    }
                else if x.mode=="couple" && @rule.couplesound=="aloud"
                    {
                        mode: "couple"
                        name: "共有者的低语"
                        comment: "沙沙声・・・"
                        time: x.time
                    }
                else
                    null
        .filter (x)->x?
    prize_check:->
        Server.prize.checkPrize @,(obj)=>
            # obj: {(userid):[prize]}
            # 賞を算出した
            pls=@players.filter (x)->x.realid!="替身君"
            # 各々に対して処理
            query={userid:{$in:pls.map (x)->x.realid}}
            M.users.find(query).each (err,doc)=>
                return unless doc?
                # 奇怪的return
                oldprize=doc.prize  # いままでの賞の一览
                # 差分をとる
                newprize=obj[doc.userid].filter (x)->!(x in oldprize)
                if newprize.length>0
                    M.users.update {userid:doc.userid},{$set:{prize:obj[doc.userid]}}
                    pl=@getPlayerReal doc.userid
                    pnames=newprize.map (plzid)->
                        Server.prize.prizeQuote Server.prize.prizeName plzid
                    log=
                        mode:"system"
                        comment:"#{pl.name} 获得了称号 #{pnames.join ''}。"
                    splashlog @id,this,log

        ###
        M.users.find(query).each (err,doc)=>
            return unless doc?
            oldprize=doc.prize  # 賞の一览
            
            # 賞を算出しなおしてもらう
            Server.prize.checkPrize doc.userid,(prize)=>
                prize=prize.concat doc.ownprize if doc.ownprize?
                # 新規に獲得した賞を探す
                newprizes= prize.filter (x)->!(x in oldprize)
                if newprizes.length>0
                    M.users.update {userid:doc.userid},{$set:{prize:prize}}
                    pl=@getPlayerReal doc.userid
                    newprizes.forEach (x)=>
                        log=
                            mode:"system"
                            comment:"#{pl.name}は#{Server.prize.prizeQuote Server.prize.prizeName x}を獲得しました。"
                        splashlog @id,this,log
                        @addGamelog {
                            id: pl.id
                            type:pl.type
                            event:"getprize"
                            flag:x
                            target:null
                        }
        ###
###
logs:[{
    mode:"day"(昼) / "system"(システムメッセージ) /  "werewolf"(狼) / "heaven"(天国) / "prepare"(开始前/终了後) / "skill"(能力ログ) / "nextturn"(游戏進行) / "audience"(观战者のひとりごと) / "monologue"(夜のひとりごと) / "voteresult" (投票结果） / "couple"(共有者) / "fox"(妖狐) / "will"(遗言)
    comment: String
    userid:Userid
    name?:String
    to:Userid / null (あると、その人だけ）
    (nextturnの場合)
      day:Number
      night:Boolean
      finished?:Boolean
    (voteresultの場合)
      voteresult:[]
      tos:Object
},...]
rule:{
    number: Number # プレイヤー数
    scapegoat : "on"(身代わり君が死ぬ) "off"(参加者が死ぬ) "no"(誰も死なない)
  }
###
# 投票箱
class VotingBox
    constructor:(@game)->
        @init()
    init:->
        # 投票箱を空にする
        @remains=1  # 残り处刑人数
        @runoffmode=false   # 重新投票中か
        @candidates=[]
        @start()
    start:->
        @votes=[]   #{player:Player, to:Player}
    setCandidates:(@candidates)->
        # 候補者をセットする[Player]
    isVoteFinished:(player)->@votes.some (x)->x.player.id==player.id
    vote:(player,voteto)->
        # power: 票数
        pl=@game.getPlayer voteto
        unless pl?
            return "这个玩家不存在"
        if pl.dead
            return "这个人已经死了"
        me=@game.getPlayer player.id
        unless me?
            return "你没有加入游戏"
        if @isVoteFinished player
            return "你已经投过票了"
        if pl.id==player.id && @game.rule.votemyself!="ok"
            return "不能向自己投票"
        @votes.push {
            player:@game.getPlayer player.id
            to:pl
            power:1
            priority:0
        }
        log=
            mode:"voteto"
            to:player.id
            comment:"#{player.name} 向 #{pl.name} 投票了"
        splashlog @game.id,@game,log
        null
    # その人の投票オブジェクトを得る
    getHisVote:(player)->
        @votes.filter((x)->x.player.id==player.id)[0]
    # 票のパワーを変更する
    votePower:(player,value,absolute=false)->
        v=@getHisVote player
        if v?
            if absolute
                v.power=value
            else
                v.power+=value
    # 優先度つける
    votePriority:(player,value,absolute=false)->
        v=@getHisVote player
        if v?
            if absolute
                v.priority=value
            else
                v.priority+=value
    # 处刑人数を増やす
    addPunishedNumber:(num)->
        @remains+=num

    isVoteAllFinished:->
        alives=@game.players.filter (x)->!x.dead
        alives.every (x)=>
            x.voted @game,@
    compareGots:(a,b)->
        # aとbをsort用に(gots)
        # aのほうが小さい: -1 <
        # bのほうが小さい: 1  >
        if a.votes>b.votes
            return 1
        else if a.votes<b.votes
            return -1
        else if a.priority>b.priority
            return 1
        else if a.priority<b.priority
            return -1
        else
            return 0
    check:->
        # return [mode,result,tos,table]
        # 投票が終わったのでアレする
        # 投票表を作る
        tos={}
        table=[]
        gots={}
        #for obj in @votes
        for pl in @game.players
            continue if pl.dead
            obj=@getHisVote pl
            o=pl.publicinfo()
            if obj?
                gots[obj.to.id] ?= {
                    votes:0
                    priority:-Infinity
                }
                go=gots[obj.to.id]
                go.votes+=obj.power
                if go.priority<obj.priority
                    go.priority=obj.priority
                tos[obj.to.id]=go.votes
                o.voteto=obj.to.id  # 投票先情報を付け加える
            table.push o
        # 獲得票数が少ない順に並べる
        cands=Object.keys(gots).sort (a,b)=>
            @compareGots gots[a],gots[b]
        
        # 獲得票数多い一览
        back=null
        tops=[]
        for id in cands by -1
            if !back? || @compareGots(gots[back],gots[id])==0
                tops.push id
                back=id
            else
                break
        if tops.length==0
            # 誰も投票していない
            return ["novote",null,tos,table]
        if tops.length>1
            # 決まらない! 重新投票になった
            if @game.rule.runoff!="no" && !@runoffmode
                @setCandidates @game.players.filter (x)->x.id in tops
                @runoffmode=true
                return ["runoff",null,tos,table]
            else
                return ["revote",null,tos,table]
        if @game.rule.runoff=="yes" && !@runoffmode
            # 候補は1人だけど决胜投票をしないといけない
            if tops.length<=1
                # 候補がたりない
                back=null
                flag=false
                tops=[]
                for id in cands by -1
                    ok=false
                    if !back?
                        ok=true
                    else if @compareGots(gots[back],gots[id])==0
                        ok=true
                    else if flag==false
                        # 决胜投票なので1回だけOK!
                        flag=true
                        ok=true
                    else
                        break
                    if ok
                        tops.push id
                        back=id
                if tops.length>1
                    @setCandidates @game.players.filter (x)->x.id in tops
                    @runoffmode=true
                    return ["runoff",null,tos,table]
        # 结果を教える
        return ["punish",@game.getPlayer(tops[0]),tos,table]

class Player
    constructor:->
        # realid:本当のid id:仮のidかもしれない name:名字 icon:头像URL
        @dead=false
        @found=null # 死体の発見状況
        @winner=null    # 勝敗
        @scapegoat=false    # 替身君かどうか
        @flag=null  # 职业ごとの自由なフラグ
        
        @will=null  # 遗言
        # もと的职业
        @originalType=@type
        @originalJobname=@getJobname()
        # 强行退出
        @norevive=false

        
    @factory:(type,main=null,sub=null,cmpl=null)->
        p=null
        if cmpl?
            # 複合 mainとsubを使用
            #cmpl: 複合の親として使用するオブジェクト
            myComplex=Object.create main #Complexから
            sample=new cmpl # 手動でComplexを継承したい
            Object.keys(sample).forEach (x)->
                delete sample[x]    # own propertyは全部消す
            for name of sample
                # sampleのown Propertyは一つもない
                myComplex[name]=sample[name]
            # 混合职业
            p=Object.create myComplex

            p.main=main
            p.sub=sub
            p.cmplFlag=null
        else if !jobs[type]?
            p=new Player
        else
            p=new jobs[type]
        p
    serialize:->
        r=
            type:@type
            id:@id
            realid:@realid
            name:@name
            dead:@dead
            scapegoat:@scapegoat
            will:@will
            flag:@flag
            winner:@winner
            originalType:@originalType
            originalJobname:@originalJobname
            norevive:@norevive
        if @isComplex()
            r.type="Complex"
            r.Complex_main=@main.serialize()
            r.Complex_sub=@sub?.serialize()
            r.Complex_type=@cmplType
            r.Complex_flag=@cmplFlag
        r
    @unserialize:(obj)->
        unless obj?
            return null

        p=if obj.type=="Complex"
            # 複合
            cmplobj=complexes[obj.Complex_type ? "Complex"]
            Player.factory null, Player.unserialize(obj.Complex_main), Player.unserialize(obj.Complex_sub),cmplobj
        else
            # 普通
            Player.factory obj.type
        p.setProfile obj    #id,realid,name...
        p.dead=obj.dead
        p.scapegoat=obj.scapegoat
        p.will=obj.will
        p.flag=obj.flag
        p.winner=obj.winner
        p.originalType=obj.originalType
        p.originalJobname=obj.originalJobname
        p.norevive=!!obj.norevive   # backward compatibility
        if p.isComplex()
            p.cmplFlag=obj.Complex_flag
        p
    # 汎用関数: Complexを再構築する（chain:Complexの列（上から））
    @reconstruct:(chain,base)->
        for cmpl,i in chain by -1
            newpl=Player.factory null,base,cmpl.sub,complexes[cmpl.cmplType]
            ###
            for ok in Object.keys cmpl
                # 自己のプロパティのみ
                unless ok=="main" || ok=="sub"
                    newpl[ok]=cmpl[ok]
            ###
            newpl.cmplFlag=cmpl.cmplFlag
            base=newpl
        base

    publicinfo:->
        # 見せてもいい情報
        {
            id:@id
            name:@name
            dead:@dead
            norevive:@norevive
        }
    # プロパティセット系(Complex対応)
    setDead:(@dead,@found)->
    setWinner:(@winner)->
    setTarget:(@target)->
    setFlag:(@flag)->
    setWill:(@will)->
    setOriginalType:(@originalType)->
    setOriginalJobname:(@originalJobname)->
    setNorevive:(@norevive)->
        
    # ログが見えるかどうか（通常の游戏中、個人宛は除外）
    isListener:(game,log)->
        if log.mode in ["day","system","nextturn","prepare","monologue","skill","will","voteto","gm","gmreply","helperwhisper","probability_table","userinfo"]
            # 全员に見える
            true
        else if log.mode in ["heaven","gmheaven"]
            # 死んでたら見える
            @dead
        else if log.mode=="voteresult"
            game.rule.voteresult!="hide"    # 隠すかどうか
        else
            false
        
    # 本人に見える职业名
    getJobDisp:->@jobname
    # 本人に見える职业タイプ
    getTypeDisp:->@type
    # 职业名を得る
    getJobname:->@jobname
    # 村人かどうか
    isHuman:->!@isWerewolf()
    # 人狼かどうか
    isWerewolf:->false
    # 洋子かどうか
    isFox:->false
    # 妖狐の仲間としてみえるか
    isFoxVisible:->false
    # 恋人かどうか
    isFriend:->false
    # Complexかどうか
    isComplex:->false
    # 教会信者かどうか
    isCult:->false
    # 吸血鬼かどうか
    isVampire:->false
    # 酒鬼かどうか
    isDrunk:->false
    # 蘇生可能性を秘めているか
    isReviver:->false
    # jobtypeが合っているかどうか（夜）
    isJobType:(type)->type==@type
    # complexのJobTypeを調べる
    isCmplType:(type)->false
    # 投票先决定
    dovote:(game,target)->
        # 戻り値にも意味があるよ！
        err=game.votingbox.vote this,target,1
        if err?
            return err
        @voteafter game,target
        return null
    voteafter:(game,target)->
    # 昼のはじまり（死体処理よりも前）
    sunrise:(game)->
    deadsunrise:(game)->
    # 昼の投票準備
    votestart:(game)->
        #@voteto=null
        return if @dead
        if @scapegoat
            # 替身君は投票
            alives=game.players.filter (x)=>!x.dead && x!=this
            r=Math.floor Math.random()*alives.length    # 投票先
            return unless alives[r]?
            #@voteto=alives[r].id
            @dovote game,alives[r].id
        
    # 夜のはじまり（死体処理よりも前）
    sunset:(game)->
    deadsunset:(game)->
    # 夜にもう寝たか
    sleeping:(game)->true
    # 夜に仕事を追えたか（基本sleepingと一致）
    jobdone:(game)->@sleeping game
    # 死んだ後でも仕事があるとfalse
    deadJobdone:(game)->true
    # 昼に投票を終えたか
    voted:(game,votingbox)->game.votingbox.isVoteFinished this
    # 夜の仕事
    job:(game,playerid,query)->
        @setTarget playerid
        null
    # 夜の仕事を行う
    midnight:(game)->
    # 夜死んでいたときにmidnightの代わりに呼ばれる
    deadnight:(game)->
    # 対象
    job_target:1    # ビットフラグ
    # 対象用の値
    @JOB_T_ALIVE:1  # 生きた人が対象
    @JOB_T_DEAD :2  # 死んだ人が対象
    #人狼に食われて死ぬかどうか
    willDieWerewolf:true
    #占いの结果
    fortuneResult:"村人"
    #灵能の结果
    psychicResult:"村人"
    #チーム Human/Werewolf
    team: "Human"
    #胜利かどうか team:胜利阵营名
    isWinner:(game,team)->
        team==@team # 自己の阵营かどうか
    # 殺されたとき(found:死因。fromは場合によりplayerid。punishの場合は[playerid]))
    die:(game,found,from)->
        return if @dead
        if found=="werewolf" && !@willDieWerewolf
            # 襲撃耐性あり
            return
        pl=game.getPlayer @id
        pl.setDead true,found
        pl.dying game,found,from
    # 死んだとき
    dying:(game,found)->
    # 行きかえる
    revive:(game)->
        # logging: ログを表示するか
        if @norevive
            # 蘇生しない
            return
        @setDead false,null
        p=@getParent game
        unless p?.sub==this
            # サブのときはいいや・・・
            log=
                mode:"system"
                comment:"#{@name} 复活了。"
            splashlog game.id,game,log
            @addGamelog game,"revive",null,null
            game.ss.publish.user @id,"refresh",{id:game.id}

    # 埋葬するまえに全员呼ばれる（foundが見られる状況で）
    beforebury: (game,type)->
    # 占われたとき（结果は別にとられる player:占い元）
    divined:(game,player)->
    # ちょっかいを出されたとき(jobのとき)
    touched:(game,from)->
    # 选择肢を返す
    makeJobSelection:(game)->
        if game.night
            # 夜の能力
            jt=@job_target
            if jt>0
                # 参加者を选择する
                result=[]
                for pl in game.players
                    if (pl.dead && (jt&Player.JOB_T_DEAD))||(!pl.dead && (jt&Player.JOB_T_ALIVE))
                        result.push {
                            name:pl.name
                            value:pl.id
                        }
            else
                result=[]
        else
            # 昼の投票
            result=[]
            if game?.votingbox
                for pl in game.votingbox.candidates
                    result.push {
                        name:pl.name
                        value:pl.id
                    }

        result
    checkJobValidity:(game,query)->
        sl=@makeJobSelection game
        return sl.length==0 || sl.some((x)->x.value==query.target)
    # 职业情報を載せる
    makejobinfo:(game,obj)->
        # 開くべき表单を配列で（生きている場合）
        obj.open ?=[]
        if !@jobdone(game) && (game.night || @chooseJobDay(game))
            obj.open.push @type
        # 职业解説のアレ
        obj.desc ?= []
        obj.desc.push {
            name:@getJobDisp()
            type:@getTypeDisp()
        }

        obj.job_target=@getjob_target()
        # 选择肢を教える {name:"名字",value:"値"}
        obj.job_selection ?= []
        obj.job_selection=obj.job_selection.concat @makeJobSelection game
        # 重複を取り除くのはクライアント側にやってもらおうかな…

        # 女王观战者が見える
        if @team=="Human"
            obj.queens=game.players.filter((x)->x.type=="QueenSpectator").map (x)->
                x.publicinfo()
        else
            # セットなどによる漏洩を防止
            delete obj.queens
    # 昼でも対象选择を行えるか
    chooseJobDay:(game)->false
    # 仕事先情報を教える
    getjob_target:->@job_target
    # 昼の发言の选择肢
    getSpeakChoiceDay:(game)->
        ["day","monologue"]
    # 夜の发言の选择肢を得る
    getSpeakChoice:(game)->
        ["monologue"]
    # Complexから抜ける
    uncomplex:(game,flag=false)->
        #flag: 自己がComplexで自己が消滅するならfalse 自己がmainまたはsubで親のComplexを消すならtrue(その際subは消滅）
        
        befpl=game.getPlayer @id

        # objがPlayerであること calleeは呼び出し元のオブジェクト chainは継承連鎖
        # index: game.playersの番号
        chk=(obj,index,callee,chain)->
            return unless obj?
            chc=chain.concat obj
            if obj.isComplex()
                if flag
                    # mainまたはsubである
                    if obj.main==callee || obj.sub==callee
                        # 自己は消える
                        game.players[index]=Player.reconstruct chain,obj.main
                    else
                        chk obj.main,index,callee,chc
                        # TODO これはよくない
                        chk obj.sub,index,callee,chc
                else
                    # 自己がComplexである
                    if obj==callee
                        game.players[index]=Player.reconstruct chain,obj.main
                    else
                        chk obj.main,index,callee,chc
                        # TODO これはよくない
                        chk obj.sub,index,callee,chc
        
        game.players.forEach (x,i)=>
            if x.id==@id
                chk x,i,this,[]
                # participantsも
                for pl,j in game.participants
                    if pl.id==@id
                        game.participants[j]=game.players[i]
                        break
                
        aftpl=game.getPlayer @id
        #前と後で比較
        if befpl.getJobname()!=aftpl.getJobname()
            aftpl.setOriginalJobname "#{befpl.originalJobname}→#{aftpl.getJobname()}"
                
    # 自己自身を変える
    transform:(game,newpl,override,initial=false)->
        # override: trueなら全部変える falseならメイン职业のみ変える
        @addGamelog game,"transform",newpl.type
        # 职业変化ログ
        if override || !@isComplex()
            # 全部取っ払ってnewplになる
            newpl.setOriginalType @originalType
            if @getJobname()!=newpl.getJobname()
                unless initial
                    # ふつうの変化
                    newpl.setOriginalJobname "#{@originalJobname}→#{newpl.getJobname()}"
                else
                    # 最初の変化（ログに残さない）
                    newpl.setOriginalJobname newpl.getJobname()
            pa=@getParent game
            unless pa?
                # 親なんていない
                game.players.forEach (x,i)=>
                    if x.id==@id
                        game.players[i]=newpl
                game.participants.forEach (x,i)=>
                    if x.id==@id
                        game.participants[i]=newpl
            else
                # 親がいた
                if pa.main==this
                    # 親書き換え
                    newparent=Player.factory null,newpl,pa.sub,complexes[pa.cmplType]
                    newparent.cmplFlag=pa.cmplFlag
                    newpl.transProfile newparent

                    pa.transform game,newparent,override # たのしい再帰
                else
                    # サブだった
                    pa.sub=newpl
        else
            # 中心のみ変える
            pa=game.getPlayer @id
            orig_originalJobname=pa.originalJobname
            chain=[pa]
            while pa.main.isComplex()
                pa=pa.main
                chain.push pa
            # pa.mainはComplexではない
            toppl=Player.reconstruct chain,newpl
            toppl.setOriginalJobname "#{orig_originalJobname}→#{toppl.getJobname()}"
            # 親なんていない
            game.players.forEach (x,i)=>
                if x.id==@id
                    game.players[i]=toppl
            game.participants.forEach (x,i)=>
                if x.id==@id
                    game.participants[i]=toppl
    getParent:(game)->
        chk=(parent,name)=>
            if parent[name]?.isComplex?()
                if parent[name].main==this || parent[name].sub==this
                    return parent[name]
                else
                    return chk(parent[name],"main") || chk(parent[name],"sub")
            else
                return null
        for pl,i in game.players
            c=chk game.players,i
            return c if c?
        return null # 親なんていない
            
    # 自己のイベントを記述
    addGamelog:(game,event,flag,target,type=@type)->
        game.addGamelog {
            id:@id
            type:type
            target:target
            event:event
            flag:flag
        }
    # 個人情報的なことをセット
    setProfile:(obj={})->
        @id=obj.id
        @realid=obj.realid
        @name=obj.name
    # 個人情報的なことを移動
    transProfile:(newpl)->
        newpl.setProfile this
    # フラグ類を新しいPlayerオブジェクトへ移動
    transferData:(newpl)->
        return unless newpl?
        newpl.scapegoat=@scapegoat
        newpl.setDead @dead,@found
        
            

        
        
        
class Human extends Player
    type:"Human"
    jobname:"村人"
class Werewolf extends Player
    type:"Werewolf"
    jobname:"人狼"
    sunset:(game)->
        @setTarget null
        unless game.day==1 && game.rule.scapegoat!="off"
            if @scapegoat && @isAttacker() && game.players.filter((x)->!x.dead && x.isWerewolf() && x.isAttacker()).length==1
                # 自己しか人狼がいない
                hus=game.players.filter (x)->!x.dead && !x.isWerewolf()
                while hus.length>0 && game.werewolf_target_remain>0
                    r=Math.floor Math.random()*hus.length
                    @job game,hus[r].id,{}
                    hus.splice r,1
                if game.werewolf_target_remain>0
                    # 襲撃したい人全员襲撃したけどまだ襲撃できるときは重複襲撃
                    hus=game.players.filter (x)->!x.dead && !x.isWerewolf()
                    while hus.length>0 && game.werewolf_target_remain>0
                        r=Math.floor Math.random()*hus.length
                        @job game,hus[r].id,{}


    sleeping:(game)->game.werewolf_target_remain<=0 || !game.night
    job:(game,playerid)->
        tp = game.getPlayer playerid
        if game.werewolf_target_remain<=0
            return "已经决定了袭击对象"
        if game.rule.wolfattack!="ok" && tp?.isWerewolf()
            # 人狼は人狼に攻撃できない
            return "人狼之间不能相互袭击"
        game.werewolf_target.push {
            from:@id
            to:playerid
        }
        game.werewolf_target_remain--
        tp.touched game,@id
        log=
            mode:"wolfskill"
            comment:"以 #{@name} 为首的人狼们决定今晚袭击 #{tp.name}。"
        if @isJobType "SolitudeWolf"
            # 孤独的狼なら自己だけ…
            log.to=@id
        splashlog game.id,game,log
        game.splashjobinfo game.players.filter (x)=>x.id!=playerid && x.isWerewolf()
        null
                
    isWerewolf:->true
    # おおかみ専用メソッド：襲撃できるか
    isAttacker:->!@dead
    
    isListener:(game,log)->
        if log.mode in ["werewolf","wolfskill"]
            true
        else super
    isJobType:(type)->
        # 便宜的
        if type=="_Werewolf"
            return true
        super
        
    willDieWerewolf:false
    fortuneResult:"人狼"
    psychicResult:"人狼"
    team: "Werewolf"
    makejobinfo:(game,result)->
        super
        if game.night && game.werewolf_target_remain>0
            # まだ襲える
            result.open.push "_Werewolf"
        # 人狼は仲間が分かる
        result.wolves=game.players.filter((x)->x.isWerewolf()).map (x)->
            x.publicinfo()
        # 间谍2も分かる
        result.spy2s=game.players.filter((x)->x.type=="Spy2").map (x)->
            x.publicinfo()
    getSpeakChoice:(game)->
        ["werewolf"].concat super

        
        
class Diviner extends Player
    type:"Diviner"
    jobname:"占卜师"
    constructor:->
        super
        @results=[]
            # {player:Player, result:String}
    sunset:(game)->
        super
        @setTarget null
        if @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            @job game,game.players[r].id,{}
    sleeping:->@target?
    job:(game,playerid)->
        super
        pl=game.getPlayer playerid
        unless pl?
            return "这个玩家不存在。"
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 占卜了 #{pl.name} 的身份。"
        splashlog game.id,game,log
        if game.rule.divineresult=="immediate"
            @dodivine game
            @showdivineresult game
        null
    sunrise:(game)->
        super
        unless game.rule.divineresult=="immediate"
            @showdivineresult game
                
    midnight:(game)->
        super
        unless game.rule.divineresult=="immediate"
            @dodivine game
        @divineeffect game
    #占った影響を与える
    divineeffect:(game)->
        p=game.getPlayer @target
        if p?
            p.divined game,this
    #占い実行
    dodivine:(game)->
        p=game.getPlayer @target
        if p?
            @results.push {
                player: p.publicinfo()
                result: "#{@name} 占卜了 #{p.name} 的身份，他是 #{p.fortuneResult}。"
            }
            @addGamelog game,"divine",p.type,@target    # 占った
    showdivineresult:(game)->
        r=@results[@results.length-1]
        return unless r?
        log=
            mode:"skill"
            to:@id
            comment:r.result
        splashlog game.id,game,log
class Psychic extends Player
    type:"Psychic"
    jobname:"灵能者"
    constructor:->
        super
        @setFlag ""    # ここにメッセージを入れよう
    sunset:(game)->
        super
        if game.rule.psychicresult=="sunset"
            @showpsychicresult game
    sunrise:(game)->
        super
        unless game.rule.psychicresult=="sunset"
            @showpsychicresult game
        
    showpsychicresult:(game)->
        return unless @flag?
        @flag.split("\n").forEach (x)=>
            return unless x
            log=
                mode:"skill"
                to:@id
                comment:x
            splashlog game.id,game,log
        @setFlag ""
    
    # 处刑で死んだ人を調べる
    beforebury:(game,type)->
        game.players.filter((x)->x.dead && x.found=="punish").forEach (x)=>
            @setFlag @flag+"根据 #{@name} 的灵能结论，被处刑的 #{x.name} 是 #{x.psychicResult}。\n"

class Madman extends Player
    type:"Madman"
    jobname:"狂人"
    team:"Werewolf"
    makejobinfo:(game,result)->
        super
        delete result.queens
class Guard extends Player
    type:"Guard"
    jobname:"猎人"
    sleeping:->@target?
    sunset:(game)->
        @setTarget null
        if game.day==1
            # 猎人は一日目护卫しない
            @setTarget ""  # 誰も守らない
        else if @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            if @job game,game.players[r].id,{}
                # 失敗した
                @setTarget ""
    job:(game,playerid)->
        unless playerid==@id && game.rule.guardmyself!="ok"
            super
            pl=game.getPlayer(playerid)
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 守护了 #{pl.name}。"
            splashlog game.id,game,log
            # 複合させる

            newpl=Player.factory null,pl,null,Guarded   # 守られた人
            pl.transProfile newpl
            newpl.cmplFlag=@id  # 护卫元cmplFlag
            pl.transform game,newpl,true
            newpl.touched game,@id
            null
        else
            "不能守护自己"
class Couple extends Player
    type:"Couple"
    jobname:"共有者"
    makejobinfo:(game,result)->
        super
        # 共有者は仲間が分かる
        result.peers=game.players.filter((x)->x.isJobType "Couple").map (x)->
            x.publicinfo()
    isListener:(game,log)->
        if log.mode=="couple"
            true
        else super
    getSpeakChoice:(game)->
        ["couple"].concat super

class Fox extends Player
    type:"Fox"
    jobname:"妖狐"
    team:"Fox"
    willDieWerewolf:false
    isHuman:->false
    isFox:->true
    isFoxVisible:->true
    makejobinfo:(game,result)->
        super
        # 妖狐は仲間が分かる
        result.foxes=game.players.filter((x)->x.isFoxVisible()).map (x)->
            x.publicinfo()
    divined:(game,player)->
        super
        # 妖狐呪殺
        @die game,"curse"
        player.addGamelog game,"cursekill",null,@id # 呪殺した
    isListener:(game,log)->
        if log.mode=="fox"
            true
        else super
    getSpeakChoice:(game)->
        ["fox"].concat super


class Poisoner extends Player
    type:"Poisoner"
    jobname:"埋毒者"
    dying:(game,found,from)->
        super
        # 埋毒者の逆襲
        canbedead = game.players.filter (x)->!x.dead    # 生きている人たち
        if found=="werewolf"
            # 噛まれた場合は狼のみ
            canbedead=canbedead.filter (x)->x.isWerewolf()
        else if found=="vampire"
            canbedead=canbedead.filter (x)->x.id==from
        return if canbedead.length==0
        r=Math.floor Math.random()*canbedead.length
        pl=canbedead[r] # 被害者
        pl.die game,"poison"
        @addGamelog game,"poisonkill",null,pl.id

class BigWolf extends Werewolf
    type:"BigWolf"
    jobname:"大狼"
    fortuneResult:"村人"
    psychicResult:"大狼"
class TinyFox extends Diviner
    type:"TinyFox"
    jobname:"小狐"
    fortuneResult:"村人"
    psychicResult:"小狐"
    team:"Fox"
    isHuman:->false
    isFox:->true
    makejobinfo:(game,result)->
        super
        # 子狐は妖狐が分かる
        result.foxes=game.players.filter((x)->x.isFoxVisible()).map (x)->
            x.publicinfo()

    job:(game,playerid)->
        super
        pl=game.getPlayer playerid
        unless pl?
            return "这个玩家不存在。"
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 占卜了 #{pl.name} 的身份。"
        splashlog game.id,game,log
        if game.rule.divineresult=="immediate"
            @dodivine game
            @showdivineresult game
        null
    sunrise:(game)->
        super
        unless game.rule.divineresult=="immediate"
            @showdivineresult game
                
    midnight:(game)->
        super
        unless game.rule.divineresult=="immediate"
            @dodivine game
    dodivine:(game)->
        p=game.getPlayer @target
        if p?
            success= Math.random()<0.5  # 成功したかどうか
            re=if success then "大概是 #{p.fortuneResult}。" else "真是一个看不透的怪人"
            @results.push {
                player: p.publicinfo()
                result: "根据 #{@name} 的占卜结果，#{p.name} #{re}"
            }
            @addGamelog game,"foxdivine",success,p.id
    showdivineresult:(game)->
        r=@results[@results.length-1]
        return unless r?
        log=
            mode:"skill"
            to:@id
            comment:r.result
        splashlog game.id,game,log
    divineeffect:(game)->
    
    
class Bat extends Player
    type:"Bat"
    jobname:"蝙蝠"
    team:""
    isWinner:(game,team)->
        !@dead  # 生きて入ればとにかく胜利
class Noble extends Player
    type:"Noble"
    jobname:"贵族"
    die:(game,found)->
        if found=="werewolf"
            return if @dead
            # 奴隶たち
            slaves = game.players.filter (x)->!x.dead && x.type=="Slave"
            unless slaves.length
                super   # 自己が死ぬ
            else
                # 奴隶が代わりに死ぬ
                slaves.forEach (x)->
                    x.die game,"werewolf2"
                    x.addGamelog game,"slavevictim"
                @addGamelog game,"nobleavoid"
        else
            super

class Slave extends Player
    type:"Slave"
    jobname:"奴隶"
    isWinner:(game,team)->
        nobles=game.players.filter (x)->!x.dead && x.type=="Noble"
        if team==@team && nobles.length==0
            true    # 村人阵营の勝ちで贵族は死んだ
        else
            false
    makejobinfo:(game,result)->
        super
        # 奴隶は贵族が分かる
        result.nobles=game.players.filter((x)->x.type=="Noble").map (x)->
            x.publicinfo()
class Magician extends Player
    type:"Magician"
    jobname:"魔术师"
    isReviver:->!@dead
    sunset:(game)->
        @setTarget (if game.day<3 then "" else null)
        if game.players.every((x)->!x.dead)
            @setTarget ""  # 誰も死んでいないなら能力発動しない
        if !@target? && @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            @job game,game.players[r].id,{}
    job:(game,playerid)->
        if game.day<3
            # まだ発動できない
            return "现在还不能发动技能"
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 复活了 #{pl.name}。"
        splashlog game.id,game,log
        null
    sleeping:(game)->game.day<3 || @target?
    midnight:(game)->
        return unless @target?
        pl=game.getPlayer @target
        return unless pl?
        return unless pl.dead
        # 確率判定
        r=if pl.scapegoat then 0.6 else 0.3
        unless Math.random()<r
            # 失敗
            @addGamelog game,"raise",false,pl.id
            return
        # 蘇生 目を覚まさせる
        @addGamelog game,"raise",true,pl.id
        pl.revive game
    job_target:Player.JOB_T_DEAD
    makejobinfo:(game,result)->
        super
class Spy extends Player
    type:"Spy"
    jobname:"间谍"
    team:"Werewolf"
    sleeping:->true # 能力使わなくてもいい
    jobdone:->@flag in ["spygone","day1"]   # 能力を使ったか
    sunrise:(game)->
        if game.day<=1
            @setFlag "day1"    # まだ去れない
        else
            @setFlag null
    job:(game,playerid)->
        return "已经发动了技能" if @flag=="spygone"
        @setFlag "spygone"
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 决定要离开村子。"
        splashlog game.id,game,log
        null
    midnight:(game)->
        if !@dead && @flag=="spygone"
            # 村を去る
            @setFlag "spygone"
            @die game,"spygone"
    job_target:0
    isWinner:(game,team)->
        team==@team && @dead && @flag=="spygone"    # 人狼が勝った上で自己は任務完了の必要あり
    makejobinfo:(game,result)->
        super
        # 间谍は人狼が分かる
        result.wolves=game.players.filter((x)->x.isWerewolf()).map (x)->
            x.publicinfo()
    makeJobSelection:(game)->
        # 夜は投票しない
        if game.night
            []
        else super
class WolfDiviner extends Werewolf
    type:"WolfDiviner"
    jobname:"人狼占卜师"
    constructor:->
        super
        @results=[]
            # {player:Player, result:String}
    sunset:(game)->
        @setTarget null
        @setFlag null  # 占い対象
        @result=null    # 占卜结果
        super
    sleeping:(game)->game.werewolf_target_remain<=0 # 占いは必須ではない
    jobdone:(game)->game.werewolf_target_remain<=0 && @flag?
    job:(game,playerid,query)->
        if query.jobtype!="WolfDiviner"
            # 人狼の仕事
            return super
        # 占い
        if @flag?
            return "已经决定占卜对象"
        pl=game.getPlayer playerid
        unless pl?
            return "这个玩家不存在。"
        @setFlag playerid
        unless pl.team=="Werewolf" && pl.isHuman()
            # 狂人は変化するので
            pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"人狼占卜师 #{@name} 占卜了 #{pl.name} 的身份。"
        splashlog game.id,game,log
        if game.rule.divineresult=="immediate"
            @dodivine game
            @showdivineresult game
        null
    sunrise:(game)->
        super
        unless game.rule.divineresult=="immediate"
            @showdivineresult game
    midnight:(game)->
        super
        @divineeffect game
        unless game.rule.divineresult=="immediate"
            @dodivine game
    #占った影響を与える
    divineeffect:(game)->
        p=game.getPlayer @flag
        if p?
            p.divined game,this
            if p.isJobType "Diviner"
                # 逆呪殺
                @die game,"curse"
    showdivineresult:(game)->
        r=@results[@results.length-1]
        return unless r?
        log=
            mode:"skill"
            to:@id
            comment:r.result
        splashlog game.id,game,log
    dodivine:(game)->
        p=game.getPlayer @flag
        if p?
            @results.push {
                player: p.publicinfo()
                result: "人狼占卜师 #{@name} 占卜了 #{p.name} 的身份，他是 #{p.jobname}。"
            }
            @addGamelog game,"wolfdivine",null,@flag  # 占った
            if p.team=="Werewolf" && p.isHuman()
                # 狂人変化
                jobnames=Object.keys jobs
                loop #避免狂人成为exceptions的职业，"GameMaster"保留
                    newjob = jobnames[Math.floor(Math.random() * jobnames.length)]
                    if ((nj) ->
                        exceptions=["MinionSelector","Thief","Helper","QuantumPlayer","Waiting","Watching"]
                        for job_denied in exceptions
                            return false  if nj is job_denied
                        true
                    )(newjob)
                        break

                plobj=p.serialize()
                plobj.type=newjob
                newpl=Player.unserialize plobj  # 新生狂人
                newpl.setFlag null
                p.transferData newpl
                p.transform game,newpl,false
                log=
                    mode:"skill"
                    to:p.id
                    comment:"#{p.name} 变成了 #{newpl.getJobDisp()}。"
                splashlog game.id,game,log
                game.splashjobinfo [game.getPlayer newpl.id]
    makejobinfo:(game,result)->
        super
        if game.night
            if @flag?
                # もう占いは終わった
                result.open = result.open?.filter (x)=>x!="WolfDiviner"

        
    
        

class Fugitive extends Player
    type:"Fugitive"
    jobname:"逃亡者"
    sunset:(game)->
        @setTarget null
        if game.day<=1 #&& game.rule.scapegoat!="off"    # 一日目は逃げない
            @setTarget ""
        else if @scapegoat
            # 身代わり君の自動占い
            als=game.players.filter (x)=>!x.dead && x.id!=@id
            if als.length==0
                @setTarget ""
                return
            r=Math.floor Math.random()*als.length
            if @job game,als[r].id,{}
                @setTarget ""
    sleeping:->@target?
    job:(game,playerid)->
        # 逃亡先
        pl=game.getPlayer playerid
        if pl?.dead
            return "不能逃到死者的家里去"
        if playerid==@id
            return "不能逃到自己的家里去"
        @setTarget playerid
        pl?.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 逃亡到 #{pl.name} 的家里去了。"
        splashlog game.id,game,log
        @addGamelog game,"runto",null,pl.id
        null
    die:(game,found)->
        # 狼の襲撃・吸血鬼の襲撃・魔女の毒薬は回避
        if found in ["werewolf","vampire","witch"]
            if @target!=""
                return
            else
                super
        else
            super
        
    midnight:(game)->
        # 人狼の家に逃げていたら即死
        pl=game.getPlayer @target
        return unless pl?
        if !pl.dead && pl.isWerewolf() && pl.team in ["Werewolf","LoneWolf"]
            @die game,"werewolf2"
        else if !pl.dead && pl.isVampire() && pl.team=="Vampire"
            @die game,"vampire2"
        
    isWinner:(game,team)->
        team==@team && !@dead   # 村人胜利で生存
class Merchant extends Player
    type:"Merchant"
    jobname:"商人"
    constructor:->
        super
        @setFlag null  # 発送済みかどうか
    sleeping:->true
    jobdone:(game)->game.day<=1 || @flag?
    job:(game,playerid,query)->
        if @flag?
            return "商品已经送出"
        # 即時発送
        unless query.Merchant_kit in ["Diviner","Psychic","Guard"]
            return "要送出的商品无效"
        kit_names=
            "Diviner":"占卜套装"
            "Psychic":"灵能套装"
            "Guard":"守护套装"
        pl=game.getPlayer playerid
        unless pl?
            return "发送无效"
        if pl.dead
            return "发送对象已经死亡"
        if pl.id==@id
            return "不能发送给自己"
        pl.touched game,@id
        # 複合させる
        sub=Player.factory query.Merchant_kit   # 副を作る
        pl.transProfile sub
        sub.sunset game
        newpl=Player.factory null,pl,sub,Complex    # Complex
        pl.transProfile newpl
        pl.transform game,newpl,true

        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 向 #{newpl.name} 寄出了 #{kit_names[query.Merchant_kit]}。"
        splashlog game.id,game,log
        # 入れ替え先は気づいてもらう
        log=
            mode:"skill"
            to:newpl.id
            comment:"#{newpl.name} 收到了礼物 #{kit_names[query.Merchant_kit]}。"
        splashlog game.id,game,log
        game.ss.publish.user newpl.id,"refresh",{id:game.id}
        @setFlag query.Merchant_kit    # 発送済み
        @addGamelog game,"sendkit",@flag,newpl.id
        null
class QueenSpectator extends Player
    type:"QueenSpectator"
    jobname:"女王观战者"
    dying:(game,found)->
        super
        # 感染
        humans = game.players.filter (x)->!x.dead && x.isHuman()    # 生きている人たち
        humans.forEach (x)->
            x.die game,"hinamizawa"

class MadWolf extends Werewolf
    type:"MadWolf"
    jobname:"狂人狼"
    team:"Human"
    sleeping:->true
class Neet extends Player
    type:"Neet"
    jobname:"NEET"
    team:""
    sleeping:->true
    voted:(game,votingbox)->true
    isWinner:->true
class Liar extends Player
    type:"Liar"
    jobname:"骗子"
    job_target:Player.JOB_T_ALIVE | Player.JOB_T_DEAD   # 死人も生存も
    constructor:->
        super
        @results=[]
    sunset:(game)->
        @setTarget null
        if @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            @job game,game.players[r].id,{}
    sleeping:->@target?
    job:(game,playerid,query)->
        # 占い
        if @target?
            return "已经决定占卜对象"
        @setTarget playerid
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 占卜了 #{pl.name} 的身份。"
        splashlog game.id,game,log
        null
    sunrise:(game)->
        super
        return if !@results? || @results.length==0
        log=
            mode:"skill"
            to:@id
            comment:"虽然不是很自信，根据骗子占卜的结果 #{@results[@results.length-1].player.name} 大概是 #{@results[@results.length-1].result}，大概。"
        splashlog game.id,game,log
    midnight:(game)->
        p=game.getPlayer @target
        if p?
            @addGamelog game,"liardivine",null,p.id
            @results.push {
                player: p.publicinfo()
                result: if Math.random()<0.3
                    # 成功
                    p.fortuneResult
                else
                    # 逆
                    switch p.fortuneResult
                        when "村人"
                            "人狼"
                        when "人狼"
                            "村人"
                        else
                            p.fortuneResult
            }
    isWinner:(game,team)->team==@team && !@dead # 村人胜利で生存
class Spy2 extends Player
    type:"Spy2"
    jobname:"间谍Ⅱ"
    team:"Werewolf"
    makejobinfo:(game,result)->
        super
        # 间谍は人狼が分かる
        result.wolves=game.players.filter((x)->x.isWerewolf()).map (x)->
            x.publicinfo()
    
    dying:(game,found)->
        super
        @publishdocument game
            
    publishdocument:(game)->
        str=game.players.map (x)->
            "#{x.name}:#{x.jobname}"
        .join " "
        log=
            mode:"system"
            comment:"发现了 #{@name} 的调查报告书。"
        splashlog game.id,game,log
        log2=
            mode:"will"
            comment:str
        splashlog game.id,game,log2
            
    isWinner:(game,team)-> team==@team && !@dead
class Copier extends Player
    type:"Copier"
    jobname:"模仿者"
    team:""
    isHuman:->false
    sleeping:->true
    jobdone:->@target?
    sunset:(game)->
        @setTarget null
        if @scapegoat
            alives=game.players.filter (x)->!x.dead
            r=Math.floor Math.random()*alives.length
            pl=alives[r]
            @job game,pl.id,{}

    job:(game,playerid,query)->
        # 模仿者先
        if @target?
            return "已经模仿了其他人"
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 模仿了 #{pl.name} 的能力。"
        splashlog game.id,game,log
        p=game.getPlayer playerid
        newpl=Player.factory p.type
        @transProfile newpl
        @transferData newpl
        @transform game,newpl,false
        pl=game.getPlayer @id
        pl.sunset game   # 初期化してあげる

        
        #game.ss.publish.user newpl.id,"refresh",{id:game.id}
        game.splashjobinfo [game.getPlayer @id]
        null
    isWinner:(game,team)->false # 模仿者しないと負け
class Light extends Player
    type:"Light"
    jobname:"死亡笔记"
    sleeping:->true
    jobdone:(game)->@target? || game.day==1
    sunset:(game)->
        @setTarget null
    job:(game,playerid,query)->
        # 模仿者先
        if @target?
            return "已经选择了对象"
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 在死亡笔记上写下了 #{pl.name} 的名字。"
        splashlog game.id,game,log
        null
    midnight:(game)->
        t=game.getPlayer @target
        return unless t?
        return if t.dead
        t.die game,"deathnote"
        
        # 誰かに移る処理
        @uncomplex game,true    # 自己からは抜ける
class Fanatic extends Madman
    type:"Fanatic"
    jobname:"狂信者"
    makejobinfo:(game,result)->
        super
        # 狂信者は人狼が分かる
        result.wolves=game.players.filter((x)->x.isWerewolf()).map (x)->
            x.publicinfo()
class Immoral extends Player
    type:"Immoral"
    jobname:"背德者"
    team:"Fox"
    beforebury:(game,type)->
        # 狐が全員死んでいたら自殺
        unless game.players.some((x)->!x.dead && x.isFox())
            @die game,"foxsuicide"
    makejobinfo:(game,result)->
        super
        # 妖狐が分かる
        result.foxes=game.players.filter((x)->x.isFoxVisible()).map (x)->
            x.publicinfo()
class Devil extends Player
    type:"Devil"
    jobname:"恶魔"
    team:"Devil"
    psychicResult:"人狼"
    die:(game,found)->
        return if @dead
        if found=="werewolf"
            # 死なないぞ！
            unless @flag
                # まだ噛まれていない
                @setFlag "bitten"
        else if found=="punish"
            # 处刑されたぞ！
            if @flag=="bitten"
                # 噛まれたあと处刑された
                @setFlag "winner"
            else
                super
        else
            super
    isWinner:(game,team)->team==@team && @flag=="winner"
class ToughGuy extends Player
    type:"ToughGuy"
    jobname:"硬汉"
    die:(game,found)->
        if found=="werewolf"
            # 狼の襲撃に耐える
            @setFlag "bitten"
        else
            super
    sunrise:(game)->
        super
        if @flag=="bitten"
            @setFlag "dying"   # 死にそう！
    sunset:(game)->
        super
        if @flag=="dying"
            # 噛まれた次の夜
            @setFlag null
            @setDead true,"werewolf"
class Cupid extends Player
    type:"Cupid"
    jobname:"丘比特"
    team:"Friend"
    constructor:->
        super
        @setFlag null  # 恋人1
        @setTarget null    # 恋人2
    sunset:(game)->
        if game.day>=2 && @flag?
            # 2日目以降はもう遅い
            @setFlag ""
            @setTarget ""
        else
            @setFlag null
            @setTarget null
            if @scapegoat
                # 身代わり君の自動占い
                alives=game.players.filter (x)->!x.dead
                i=0
                while i++<2
                    r=Math.floor Math.random()*alives.length
                    @job game,alives[r].id,{}
                    alives.splice r,1
    sleeping:->@flag? && @target?
    job:(game,playerid,query)->
        if @flag? && @target?
            return "已经决定了对象"
    
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        
        unless @flag?
            @setFlag playerid
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 把 #{pl.name} 定为恋人中的一人。"
            splashlog game.id,game,log
            return null
        if @flag==playerid
            return "请选择另一个恋人"
            
        @setTarget playerid
        # 恋人二人が决定した
        
        plpls=[game.getPlayer(@flag), game.getPlayer(@target)]
        for pl,i in plpls
            # 2人ぶん処理
        
            pl.touched game,@id
            newpl=Player.factory null,pl,null,Friend    # 恋人だ！
            pl.transProfile newpl
            pl.transform game,newpl,true # 入れ替え
            newpl.cmplFlag=plpls[1-i].id
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 向 #{newpl.name}射出了爱之箭。"
            splashlog game.id,game,log
            log=
                mode:"skill"
                to:newpl.id
                comment:"#{newpl.name} 成为了恋人。"
            splashlog game.id,game,log
        # 2人とも更新する
        for pl in [game.getPlayer(@flag), game.getPlayer(@target)]
            game.ss.publish.user pl.id,"refresh",{id:game.id}

        null
# 跟踪狂
class Stalker extends Player
    type:"Stalker"
    jobname:"跟踪狂"
    team:""
    sunset:(game)->
        super
        if !@flag   # ストーキング先を決めていない
            @setTarget null
            if @scapegoat
                alives=game.players.filter (x)->!x.dead
                r=Math.floor Math.random()*alives.length
                pl=alives[r]
                @job game,pl.id,{}
        else
            @setTarget ""
    sleeping:->@flag?
    job:(game,playerid,query)->
        if @target? || @flag?
            return "已经决定了对象"
    
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        pl.touched game,@id
        @setTarget playerid
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 跟踪了 #{pl.name}（#{pl.jobname}）。"
        splashlog game.id,game,log
        @setFlag playerid  # ストーキング対象プレイヤー
        null
    isWinner:(game,team)->
        @isWinnerStalk game,team,[]
    # 跟踪狂連鎖対応版
    isWinnerStalk:(game,team,ids)->
        if @id in ids
            # ループしてるので負け
            return false
        pl=game.getPlayer @flag
        return false unless pl?
        if team==pl.team
            return true
        if pl.isJobType "Stalker"
            # 跟踪狂を追跡
            return pl.isWinnerStalk game,team,ids.concat @id
        else
            return pl.isWinner game,team

    makejobinfo:(game,result)->
        super
        p=game.getPlayer @flag
        if p?
            result.stalking=p.publicinfo()
# 被诅咒者
class Cursed extends Player
    type:"Cursed"
    jobname:"被诅咒者"
    die:(game,found)->
        return if @dead
        if found=="werewolf"
            # 噛まれた場合人狼侧になる
            unless @flag
                # まだ噛まれていない
                @setFlag "bitten"
        else if found=="vampire"
            # 吸血鬼にもなる!!!
            unless @flag
                # まだ噛まれていない
                @setFlag "vampire"
        else
            super
    sunset:(game)->
        if @flag in ["bitten","vampire"]
            # この夜から変化する
            log=null
            newpl=null
            if @flag=="bitten"
                log=
                    mode:"skill"
                    to:@id
                    comment:"#{@name} 受到诅咒变成了人狼。"
            
                newpl=Player.factory "Werewolf"
            else
                log=
                    mode:"skill"
                    to:@id
                    comment:"#{@name} 受到诅咒变成了吸血鬼。"
            
                newpl=Player.factory "Vampire"

            @transProfile newpl
            @transferData newpl
            @transform game,newpl,false
            newpl.sunset game
                    
            splashlog game.id,game,log
            if @flag=="bitten"
                # 人狼侧に知らせる
                #game.ss.publish.channel "room#{game.id}_werewolf","refresh",{id:game.id}
                game.splashjobinfo game.players.filter (x)=>x.id!=@id && x.isWerewolf()
            else
                # 吸血鬼に知らせる
                game.splashjobinfo game.players.filter (x)=>x.id!=@id && x.isVampire()
            # 自己も知らせる
            #game.ss.publish.user newpl.realid,"refresh",{id:game.id}
            game.splashjobinfo [this]
class ApprenticeSeer extends Player
    type:"ApprenticeSeer"
    jobname:"见习占卜师"
    beforebury:(game,type)->
        # 占卜师が誰か死んでいたら占卜师に進化
        if game.players.some((x)->x.dead && x.isJobType("Diviner")) || game.players.every((x)->!x.isJobType("Diviner"))
            newpl=Player.factory "Diviner"
            @transProfile newpl
            @transferData newpl
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 从 #{@jobname} 变成了 #{newpl.jobname}。"
            splashlog game.id,game,log
            
            @transform game,newpl,false
            
            # 更新
            game.ss.publish.user newpl.realid,"refresh",{id:game.id}
class Diseased extends Player
    type:"Diseased"
    jobname:"病人"
    dying:(game,found)->
        super
        if found=="werewolf"
            # 噛まれた場合次の日人狼襲撃できない！
            game.werewolf_flag.push "Diseased"   # 病人フラグを立てる
class Spellcaster extends Player
    type:"Spellcaster"
    jobname:"诅咒师"
    sleeping:->true
    jobdone:->@target?
    sunset:(game)->
        @setTarget null
        if game.day==1
            # 初日は発動できません
            @setTarget ""
    job:(game,playerid,query)->
        if @target?
            return "已经选择了对象"
        arr=[]
        try
          arr=JSON.parse @flag
        catch error
          arr=[]
        unless arr instanceof Array
            arr=[]
        if playerid in arr
            # 既に呪いをかけたことがある
            return "这个对象已经被诅咒过了。"
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 诅咒了 #{pl.name}。"
        splashlog game.id,game,log
        arr.push playerid
        @setFlag JSON.stringify arr
        null
    midnight:(game)->
        t=game.getPlayer @target
        return unless t?
        return if t.dead
        log=
            mode:"skill"
            to:t.id
            comment:"#{t.name} 受到了诅咒。白天无法发言。"
        splashlog game.id,game,log
        
        # 複合させる

        newpl=Player.factory null,t,null,Muted  # 黙る人
        t.transProfile newpl
        t.transform game,newpl,true
class Lycan extends Player
    type:"Lycan"
    jobname:"狼凭"
    fortuneResult:"人狼"
class Priest extends Player
    type:"Priest"
    jobname:"圣职者"
    sleeping:->true
    jobdone:->@flag?
    sunset:(game)->
        @setTarget null
    job:(game,playerid,query)->
        if @flag?
            return "已经使用了能力"
        if @target?
            return "已经选择了对象"
        pl=game.getPlayer playerid
        unless pl?
            return "这个对象不存在"
        if playerid==@id
            return "不能将自己选为对象"
        pl.touched game,@id

        @setTarget playerid
        @setFlag "done"    # すでに能力を発動している
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 以神圣的力量守护了 #{pl.name}。"
        splashlog game.id,game,log
        
        # その場で変える
        # 複合させる

        newpl=Player.factory null,pl,null,HolyProtected # 守られた人
        pl.transProfile newpl
        newpl.cmplFlag=@id  # 护卫元
        pl.transform game,newpl,true

        null
class Prince extends Player
    type:"Prince"
    jobname:"王子"
    die:(game,found)->
        if found=="punish" && !@flag?
            # 处刑された
            @setFlag "used"    # 能力使用済
            log=
                mode:"system"
                comment:"#{@name} 是 #{@jobname}。本次处刑被取消了。"
            splashlog game.id,game,log
            @addGamelog game,"princeCO"
        else
            super
# Paranormal Investigator
class PI extends Diviner
    type:"PI"
    jobname:"超常现象研究者"
    sleeping:->true
    jobdone:->@flag?
    job:(game,playerid)->
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 调查了 #{pl.name} 的周边。"
        splashlog game.id,game,log
        if game.rule.divineresult=="immediate"
            @dodivine game
            @showdivineresult game
        @setFlag "done"    # 能力一回限り
        null
    #占い実行
    dodivine:(game)->
        pls=[]
        game.players.forEach (x,i)=>
            if x.id==@target
                pls.push x
                # 前
                if i==0
                    pls.push game.players[game.players.length-1]
                else
                    pls.push game.players[i-1]
                # 後
                if i>=game.players.length-1
                    pls.push game.players[0]
                else
                    pls.push game.players[i+1]
                
        
        if pls.length>0
            rs=pls.map((x)->x?.fortuneResult).filter((x)->x!="村人")    # 村人以外
            # 重複をとりのぞく
            nrs=[]
            rs.forEach (x,i)->
                if rs.indexOf(x,i+1)<0
                    nrs.push x
            tpl=game.getPlayer @target
            resultstring=if nrs.length>0
                @addGamelog game,"PIdivine",true,tpl.id
                "发现了 #{nrs.join ","} 活动的迹象"
            else
                @addGamelog game,"PIdivine",false,tpl.id
                "发现全员都是村人"
            @results.push {
                player:game.getPlayer(@target).publicinfo()
                result:"#{@name} 调查了 #{tpl.name} 的周边，#{resultstring}。"
            }
    showdivineresult:(game)->
        r=@results[@results.length-1]
        return unless r?
        log=
            mode:"skill"
            to:@id
            comment:r.result
        splashlog game.id,game,log
class Sorcerer extends Diviner
    type:"Sorcerer"
    jobname:"妖术师"
    team:"Werewolf"
    sleeping:->@target?
    job:(game,playerid)->
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 用妖术调查了 #{pl.name}。"
        splashlog game.id,game,log
        if game.rule.divineresult=="immediate"
            @dodivine game
            @showdivineresult game
        null
    #占い実行
    dodivine:(game)->
        pl=game.getPlayer @target
        if pl?
            resultstring=if pl.isJobType "Diviner"
                "是占卜师"
            else
                "不是占卜师"
            @results.push {
                player: game.getPlayer(@target).publicinfo()
                result: "#{@name} 用妖术调查了 #{pl.name}，他#{resultstring}。"
            }
    showdivineresult:(game)->
        r=@results[@results.length-1]
        return unless r?
        log=
            mode:"skill"
            to:@id
            comment:r.result
        splashlog game.id,game,log
    divineeffect:(game)->
class Doppleganger extends Player
    type:"Doppleganger"
    jobname:"二重身"
    sleeping:->true
    jobdone:->@flag?
    team:"" # 最初はチームに属さない!
    job:(game,playerid)->
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        if pl.id==@id
            return "不能将自己选为对象"
        if pl.dead
            return "对象已经死亡"
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 成为了 #{game.getPlayer(playerid).name} 的二重身。"
        splashlog game.id,game,log
        @setFlag playerid  # 二重身先
        null
    beforebury:(game,type)->
        founds=game.players.filter (x)->x.dead && x.found
        # 対象が死んだら移る
        if founds.some((x)=>x.id==@flag)
            p=game.getPlayer @flag  # その人

            newplmain=Player.factory p.type
            @transProfile newplmain
            @transferData newplmain
            
            me=game.getPlayer @id
            # まだ二重身できる
            sub=Player.factory "Doppleganger"
            @transProfile sub
            
            newpl=Player.factory null, newplmain,sub,Complex    # 合体
            @transProfile newpl
            
            pa=@getParent game  # 親を得る
            unless pa?
                # 親はいない
                @transform game,newpl,false
            else
                # 親がいる
                if pa.sub==this
                    # subなら親ごと置換
                    pa.transform game,newpl,false
                else
                    # mainなら自己だけ置換
                    @transform game,newpl,false
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 变成了 #{newpl.getJobDisp()}。"
            splashlog game.id,game,log
            @addGamelog game,"dopplemove",newpl.type,newpl.id

        
            game.ss.publish.user newpl.realid,"refresh",{id:game.id}
class CultLeader extends Player
    type:"CultLeader"
    jobname:"邪教主"
    team:"Cult"
    sleeping:->@target?
    sunset:(game)->
        super
        @setTarget null
        if @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            @job game,game.players[r].id,{}
    job:(game,playerid)->
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 发展 #{pl.name} 成为信者。"
        splashlog game.id,game,log
        @addGamelog game,"brainwash",null,playerid
        null
    midnight:(game)->
        t=game.getPlayer @target
        return unless t?
        return if t.dead
        log=
            mode:"skill"
            to:t.id
            comment:"#{t.name} 成为了教会的信者。"

        # 信者
        splashlog game.id,game,log
        newpl=Player.factory null, t,null,CultMember    # 合体
        t.transProfile newpl
        t.transform game,newpl,true

    makejobinfo:(game,result)->
        super
        # 信者は分かる
        result.cultmembers=game.players.filter((x)->x.isCult()).map (x)->
            x.publicinfo()
class Vampire extends Player
    type:"Vampire"
    jobname:"吸血鬼"
    team:"Vampire"
    willDieWerewolf:false
    fortuneResult:"吸血鬼"
    sleeping:(game)->@target? || game.day==1
    isHuman:->false
    isVampire:->true
    sunset:(game)->
        @setTarget null
        if game.day>1 && @scapegoat
            r=Math.floor Math.random()*game.players.length
            if @job game,game.players[r].id,{}
                @setTarget ""
    job:(game,playerid,query)->
        # 襲う先
        if @target?
            return "已经选择了对象"
        if game.day==1
            return "今天不能袭击"
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 袭击了 #{pl.name}。"
        splashlog game.id,game,log
        null
    midnight:(game)->
        t=game.getPlayer @target
        return unless t?
        return if t.dead
        t.die game,"vampire",@id
        # 逃亡者を探す
        runners=game.players.filter (x)=>!x.dead && x.isJobType("Fugitive") && x.target==t.id
        runners.forEach (x)=>
            x.die game,"vampire2",@id   # その家に逃げていたら逃亡者も死ぬ
    makejobinfo:(game,result)->
        super
        # 吸血鬼が分かる
        result.vampires=game.players.filter((x)->x.isVampire()).map (x)->
            x.publicinfo()
class LoneWolf extends Werewolf
    type:"LoneWolf"
    jobname:"一匹狼"
    team:"LoneWolf"
    isWinner:(game,team)->team==@team && !@dead
class Cat extends Poisoner
    type:"Cat"
    jobname:"猫又"
    isReviver:->true
    sunset:(game)->
        @setTarget (if game.day<2 then "" else null)
        if game.players.every((x)->!x.dead)
            @setTarget ""  # 誰も死んでいないなら能力発動しない
        if !@target? && @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            if @job game,game.players[r].id,{}
                @setTarget ""
    job:(game,playerid)->
        if game.day<2
            # まだ発動できない
            return "现在还不能发动能力"
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 复活了 #{pl.name}。"
        splashlog game.id,game,log
        null
    jobdone:->@target?
    sleeping:->true
    midnight:(game)->
        return unless @target?
        pl=game.getPlayer @target
        return unless pl?
        return unless pl.dead
        # 確率判定
        r=Math.random() # 0<=r<1
        unless r<=0.25
            # 失敗
            @addGamelog game,"catraise",false,pl.id
            return
        if r<=0.05
            # 5%の確率で誤爆
            deads=game.players.filter (x)->x.dead
            if deads.length==0
                # 誰もいないじゃん
                @addGamelog game,"catraise",false,pl.id
                return
            pl=deads[Math.floor(Math.random()*deads.length)]
            @addGamelog game,"catraise",pl.id,@target
        else
            @addGamelog game,"catraise",true,@target
        # 蘇生 目を覚まさせる
        pl.revive game
    deadnight:(game)->
        @setTarget @id
        @midnight game
        
    job_target:Player.JOB_T_DEAD
    makejobinfo:(game,result)->
        super
class Witch extends Player
    type:"Witch"
    jobname:"魔女"
    isReviver:->!@dead
    job_target:Player.JOB_T_ALIVE | Player.JOB_T_DEAD   # 死人も生存も
    sleeping:->true
    jobdone:->@target? || (@flag in [3,5,6])
    # @flag:ビットフラグ 1:殺害1使用済 2:殺害2使用済 4:蘇生使用済 8:今晩蘇生使用 16:今晩殺人使用
    constructor:->
        super
        @setFlag 0 # 発送済みかどうか
    sunset:(game)->
        @setTarget null
        unless @flag
            @setFlag 0
    job:(game,playerid,query)->
        # query.Witch_drug
        pl=game.getPlayer playerid
        unless pl?
            return "魔药使用无效"
        if pl.id==@id
            return "不能对自己使用魔药"
        pl.touched game,@id

        if query.Witch_drug=="kill"
            # 毒薬
            if game.day==1
                return "今天不能使用毒药"
            if (@flag&3)==3
                # 蘇生薬は使い切った
                return "已经不能使用毒药了"
            else if (@flag&4) && (@flag&3)
                # すでに薬は2つ使っている
                return "已经不能使用毒药了"
            
            if pl.dead
                return "使用目标已经死亡"
            
            # 薬を使用
            @flag |= 16 # 今晩殺害使用
            if (@flag&1)==0
                @flag |= 1  # 1つ目
            else
                @flag |= 2  # 2つ目
            @setTarget playerid
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 对 #{pl.name} 使用了毒药。"
            splashlog game.id,game,log
        else
            # 蘇生薬
            if (@flag&3)==3 || (@flag&4)
                return "已经不能使用复活药了"
            
            if !pl.dead
                return "使用对象活着"
            
            # 薬を使用
            @flag |= 12
            @setTarget playerid
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 对 #{pl.name} 使用了复活药。"
            splashlog game.id,game,log
        null
    midnight:(game)->
        return unless @target?
        pl=game.getPlayer @target
        return unless pl?
        
        if @flag & 8
            # 蘇生
            @setFlag @flag^8
            # 蘇生 目を覚まさせる
            @addGamelog game,"witchraise",null,pl.id
            pl.revive game
        else if @flag & 16
            # 殺害
            @setFlag @flag^16
            @addGamelog game,"witchkill",null,pl.id
            pl.die game,"witch"
class Oldman extends Player
    type:"Oldman"
    jobname:"老人"
    midnight:(game)->
        # 夜の終わり
        wolves=game.players.filter (x)->x.isWerewolf() && !x.dead
        if wolves.length*2<=game.day
            # 寿命
            @die game,"infirm"
class Tanner extends Player
    type:"Tanner"
    jobname:"皮革匠"
    team:""
    die:(game,found)->
        if found in ["gone-day","gone-night","gone-norevive"]
            # 突然死はダメ
            @setFlag "gone"
        super
    isWinner:(game,team)->@dead && @flag!="gone"
class OccultMania extends Player
    type:"OccultMania"
    jobname:"怪诞狂热者"
    sleeping:(game)->@target? || game.day<2
    sunset:(game)->
        @setTarget (if game.day>=2 then null else "")
        if !@target? && @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            if @job game,game.players[r].id,{}
                @setTarget ""
    job:(game,playerid)->
        if game.day<2
            # まだ発動できない
            return "现在不能使用能力"
        @setTarget playerid
        pl=game.getPlayer playerid
        unless pl?
            return "这个对象不存在"
        if pl.dead
            return "对象已经死亡"
        pl.touched game,@id
        
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 指定了 #{pl.name}。"
        splashlog game.id,game,log
        null
    midnight:(game)->
        p=game.getPlayer @target
        return unless p?
        # 変化先决定
        type="Human"
        if p.isJobType "Diviner"
            type="Diviner"
        else if p.isWerewolf()
            type="Werewolf"
        
        newpl=Player.factory type
        @transProfile newpl
        @transferData newpl
        newpl.sunset game   # 初期化してあげる
        @transform game,newpl,false

        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 变成了 #{newpl.getJobDisp()}。"
        splashlog game.id,game,log

        
        game.ss.publish.user newpl.realid,"refresh",{id:game.id}
        null

# 狼之子
class WolfCub extends Werewolf
    type:"WolfCub"
    jobname:"狼之子"
    dying:(game,found)->
        super
        game.werewolf_flag.push "WolfCub"
# 低语狂人
class WhisperingMad extends Fanatic
    type:"WhisperingMad"
    jobname:"低语狂人"

    getSpeakChoice:(game)->
        ["werewolf"].concat super
    isListener:(game,log)->
        if log.mode=="werewolf"
            true
        else super
class Lover extends Player
    type:"Lover"
    jobname:"求爱者"
    team:"Friend"
    constructor:->
        super
        @setTarget null    # 相手
    sunset:(game)->
        unless @flag?
            if @scapegoat
                # 替身君は求愛しない
                @setFlag true
                @setTarget ""
            else
                @setTarget null
    sleeping:(game)->@flag || @target?
    job:(game,playerid,query)->
        if @target?
            return "已经决定了对象"
        if @flag
            return "已经不能射出爱之箭"
    
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        if playerid==@id
            return "请选择自己以外的对象"
        pl.touched game,@id

        @setTarget playerid
        @setFlag true
        # 恋人二人が决定した
        
    
        plpls=[this,pl]
        for x,i in plpls
            newpl=Player.factory null,x,null,Friend # 恋人だ！
            x.transProfile newpl
            x.transform game,newpl,true  # 入れ替え
            newpl.cmplFlag=plpls[1-i].id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 向 #{pl.name} 求爱了。"
        splashlog game.id,game,log
        log=
            mode:"skill"
            to:newpl.id
            comment:"#{pl.name} 被告白成为了恋人。"
        splashlog game.id,game,log
        # 2人とも更新する
        for pl in [this, pl]
            game.ss.publish.user pl.id,"refresh",{id:game.id}

        null
    

# 仆从选择者
class MinionSelector extends Player
    type:"MinionSelector"
    jobname:"仆从选择者"
    team:"Werewolf"
    sleeping:(game)->@target? || game.day>1 # 初日のみ
    sunset:(game)->
        @setTarget (if game.day==1 then null else "")
        if !@target? && @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            if @job game,game.players[r].id,{}
                @setTarget ""
    
    job:(game,playerid)->
        if game.day!=1
            # まだ発動できない
            return "现在还不能发动能力"
        @setTarget playerid
        pl=game.getPlayer playerid
        unless pl?
            return "这个对象不存在"
        if pl.dead
            return "对象已经死亡"
        
        # 複合させる
        newpl=Player.factory null,pl,null,WolfMinion    # WolfMinion
        pl.transProfile newpl
        pl.transform game,newpl,true
        log=
            mode:"wolfskill"
            comment:"#{@name} 指定 #{pl.name}（#{pl.jobname}）成为了狼的仆从。"
        splashlog game.id,game,log

        log=
            mode:"skill"
            to:pl.id
            comment:"#{pl.name} 变成了狼的仆从。"
        splashlog game.id,game,log

        null
# 小偷
class Thief extends Player
    type:"Thief"
    jobname:"小偷"
    team:""
    sleeping:(game)->@target? || game.day>1
    sunset:(game)->
        @setTarget (if game.day==1 then null else "")
        # @flag:JSON的职业候補配列
        if !target?
            arr=JSON.parse(@flag ? '["Human"]')
            jobnames=arr.map (x)->
                testpl=new jobs[x]
                testpl.getJobDisp()
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 可以选择的职业有 #{jobnames.join(",")}。"
            splashlog game.id,game,log
            if @scapegoat
                # 身代わり君
                r=Math.floor Math.random()*arr.length
                @job game,arr[r]
    job:(game,target)->
        @setTarget target
        unless jobs[target]?
            return "不能变成那个职业"

        newpl=Player.factory target
        @transProfile newpl
        @transferData newpl
        newpl.sunset game
        @transform game,newpl,false
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 变成了 #{newpl.getJobDisp()}。"
        splashlog game.id,game,log
        
        game.ss.publish.user newpl.id,"refresh",{id:game.id}
        null
    makeJobSelection:(game)->
        if game.night
            # 职业から选择
            arr=JSON.parse(@flag ? '["Human"]')
            arr.map (x)->
                testpl=new jobs[x]
                {
                    name:testpl.getJobDisp()
                    value:x
                }
        else super
class Dog extends Player
    type:"Dog"
    jobname:"犬"
    fortuneResult:"人狼"
    psychicResult:"人狼"
    sunset:(game)->
        super
        @setTarget null    # 1日目:飼い主选择 选择後:かみ殺す人选择
        if !@flag?   # 飼い主を決めていない
            if @scapegoat
                alives=game.players.filter (x)=>!x.dead && x.id!=@id
                if alives.length>0
                    r=Math.floor Math.random()*alives.length
                    pl=alives[r]
                    @job game,pl.id,{}
                else
                    @setFlag ""
                    @setTarget ""
        else
            # 飼い主を护卫する
            pl=game.getPlayer @flag
            if pl?
                if pl.dead
                    # もう死んでるじゃん
                    @setTarget ""  # 洗濯済み
                else
                    newpl=Player.factory null,pl,null,Guarded   # 守られた人
                    pl.transProfile newpl
                    newpl.cmplFlag=@id  # 护卫元cmplFlag
                    pl.transform game,newpl,true

    sleeping:->@flag?
    jobdone:->@target?
    job:(game,playerid,query)->
        if @target?
            return "已经决定了对象"
    
        unless @flag?
            pl=game.getPlayer playerid
            unless pl?
                return "对象无效"
            if pl.id==@id
                return "不能成为自己的饲主。"
            pl.touched game,@id
            # 飼い主を选择した
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 选择 #{pl.name} 成为了自己的饲主。"
            splashlog game.id,game,log
            @setFlag playerid  # 飼い主
            @setTarget ""  # 襲撃対象はなし
        else
            # 襲う
            pl=game.getPlayer @flag
            @setTarget @flag
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 袭击了 #{pl.name}。"
            splashlog game.id,game,log
        null
    midnight:(game)->
        return unless @target?
        pl=game.getPlayer @target
        return unless pl?

        # 殺害
        @addGamelog game,"dogkill",pl.type,pl.id
        pl.die game,"dog"
        null
    makejobinfo:(game,result)->
        super
        if !@jobdone(game) && game.night
            if @flag?
                # 飼い主いる
                pl=game.getPlayer @flag
                if pl?
                    if !pl.read
                        result.open.push "Dog1"
                    result.dogOwner=pl.publicinfo()

            else
                result.open.push "Dog2"
    makeJobSelection:(game)->
        # 噛むときは対象选择なし
        if game.night && @flag?
            []
        else super
class Dictator extends Player
    type:"Dictator"
    jobname:"独裁者"
    sleeping:->true
    jobdone:(game)->@flag? || game.night
    chooseJobDay:(game)->true
    job:(game,playerid,query)->
        if @flag?
            return "已经不能发动能力了"
        if game.night
            return "夜晚不能发的能力"
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        pl.touched game,@id
        @setTarget playerid    # 处刑する人
        log=
            mode:"system"
            comment:"独裁者 #{@name} 宣布将要处刑 #{pl.name}。"
        splashlog game.id,game,log
        @setFlag true  # 使用済
        # その場で殺す!!!
        pl.die game,"punish",[@id]
        # 天黑了
        log=
            mode:"system"
            comment:"独裁者 #{@name} 宣布，现在天黑了。"
        splashlog game.id,game,log
        # 強制的に次のターンへ
        game.nextturn()
        null
class SeersMama extends Player
    type:"SeersMama"
    jobname:"占卜师的妈妈"
    sleeping:->true
    sunset:(game)->
        unless @flag
            # まだ能力を実行していない
            # 占卜师を探す
            divs = game.players.filter (pl)->pl.isJobType "Diviner"
            divsstr=if divs.length>0
                "#{divs.map((x)->x.name).join ','} 是占卜师。"
            else
                "没有占卜师。"
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 是占卜师的妈妈。#{divsstr}。"
            splashlog game.id,game,log
            @setFlag true  #使用済
class Trapper extends Player
    type:"Trapper"
    jobname:"陷阱师"
    sleeping:->@target?
    sunset:(game)->
        @setTarget null
        if game.day==1
            # 一日目は护卫しない
            @setTarget ""  # 誰も守らない
        else if @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            if @job game,game.players[r].id,{}
                @sunset game
    job:(game,playerid)->
        unless playerid==@id && game.rule.guardmyself!="ok"
            if playerid==@flag
                # 前も护卫した
                return "不能连续两天守护一个人"
            @setTarget playerid
            @setFlag playerid
            pl=game.getPlayer(playerid)
            pl.touched game,@id
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 的陷阱守护了 #{pl.name}。"
            splashlog game.id,game,log
            # 複合させる

            newpl=Player.factory null,pl,null,TrapGuarded   # 守られた人
            pl.transProfile newpl
            newpl.cmplFlag=@id  # 护卫元cmplFlag
            pl.transform game,newpl,true
            null
        else
            "不能守护自己"
class WolfBoy extends Madman
    type:"WolfBoy"
    jobname:"狼少年"
    sleeping:->true
    jobdone:->@target?
    sunset:(game)->
        @setTarget null
        if @scapegoat
            # 身代わり君の自動占い
            r=Math.floor Math.random()*game.players.length
            if @job game,game.players[r].id,{}
                @sunset game
    job:(game,playerid)->
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 把 #{pl.name} 伪装成了人狼。"
        splashlog game.id,game,log
        # 複合させる

        newpl=Player.factory null,pl,null,Lycanized
        pl.transProfile newpl
        newpl.cmplFlag=@id  # 护卫元cmplFlag
        pl.transform game,newpl,true
        null
class Hoodlum extends Player
    type:"Hoodlum"
    jobname:"流氓"
    team:""
    constructor:->
        super
        @setFlag "[]"  # 殺したい対象IDを入れておく
        @setTarget null
    sunset:(game)->
        unless @target?
            # 2人選んでもらう
            @setTarget null
            if @scapegoat
                # 身代わり
                alives=game.players.filter (x)=>!x.dead && x!=this
                i=0
                while i++<2 && alives.length>0
                    r=Math.floor Math.random()*alives.length
                    @job game,alives[r].id,{}
                    alives.splice r,1
    sleeping:->@target?
    job:(game,playerid,query)->
        if @target?
            return "已经决定了对象"
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        plids=JSON.parse(@flag)
        if pl.id in plids
            # 既にいる
            return "#{pl.name} 已经被选为对象"
        plids.push pl.id
        @setFlag JSON.stringify plids
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 憎恨 #{pl.name}。"
        splashlog game.id,game,log
        if plids.length>=2
            @setTarget ""
        else
            # 2人目を選んでほしい
            @setTarget null
        null

    isWinner:(game,team)->
        if @dead
            # 死んでたらだめ
            return false
        pls=JSON.parse(@flag).map (id)->game.getPlayer id
        return pls.every (pl)->pl?.dead==true
class QuantumPlayer extends Player
    type:"QuantumPlayer"
    jobname:"量子人类"
    getJobname:->
        flag=JSON.parse(@flag||"{}")
        jobname=null
        if flag.Human==1
            jobname="村人"
        else if flag.Diviner==1
            jobname="占卜师"
        else if flag.Werewolf==1
            jobname="人狼"

        numstr=""
        if flag.number?
            numstr="##{flag.number}"
        ret=if jobname?
            "量子人类#{numstr}（#{jobname}）"
        else
            "量子人类#{numstr}"
        if @originalJobname != ret
            # 収束したぞ!
            @setOriginalJobname ret
        return ret
    sleeping:->
        tarobj=JSON.parse(@target || "{}")
        tarobj.Diviner? && tarobj.Werewolf?   # 両方指定してあるか
    sunset:(game)->
        #  @flagに{Human:(確率),Diviner:(確率),Werewolf:(確率),dead:(確率)}的なのが入っているぞ!
        obj=JSON.parse(@flag || "{}")
        tarobj=
            Diviner:null
            Werewolf:null
        if obj.Diviner==0
            tarobj.Diviner=""   # なし
        if obj.Werewolf==0 || (game.rule.quantumwerewolf_firstattack!="on" && game.day==1)
            tarobj.Werewolf=""

        @setTarget JSON.stringify tarobj
        if @scapegoat
            # 身代わり君の自動占い
            unless tarobj.Diviner?
                r=Math.floor Math.random()*game.players.length
                @job game,game.players[r].id,{
                    jobtype:"_Quantum_Diviner"
                }
            unless tarobj.Werewolf?
                nonme =game.players.filter (pl)=> pl!=this
                r=Math.floor Math.random()*nonme.length
                @job game,nonme[r].id,{
                    jobtype:"_Quantum_Werewolf"
                }
    isJobType:(type)->
        # 便宜的
        if type=="_Quantum_Diviner" || type=="_Quantum_Werewolf"
            return true
        super
    job:(game,playerid,query)->
        tarobj=JSON.parse(@target||"{}")
        pl=game.getPlayer playerid
        unless pl?
            return "这个对象不存在"
        if query.jobtype=="_Quantum_Diviner" && !tarobj.Diviner?
            tarobj.Diviner=playerid
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 占卜了 #{pl.name} 的身份。"
            splashlog game.id,game,log
        else if query.jobtype=="_Quantum_Werewolf" && !tarobj.Werewolf?
            if @id==playerid
                return "不能袭击自己。"
            tarobj.Werewolf=playerid
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 决定要袭击 #{pl.name}。"
            splashlog game.id,game,log
        else
            return "对象选择无效"
        @setTarget JSON.stringify tarobj

        null
    midnight:(game)->
        # ここで処理
        tarobj=JSON.parse(@target||"{}")
        if tarobj.Diviner
            pl=game.getPlayer tarobj.Diviner
            if pl?
                # 一旦自己が占卜师のやつ以外排除
                pats=game.quantum_patterns.filter (obj)=>
                    obj[@id].jobtype=="Diviner" && obj[@id].dead==false
                # 1つ選んで占卜结果を决定
                if pats.length>0
                    index=Math.floor Math.random()*pats.length
                    j=pats[index][tarobj.Diviner].jobtype
                    if j == "Werewolf"
                        log=
                            mode:"skill"
                            to:@id
                            comment:"#{@name} 占卜了 #{pl.name} 的身份，是 人狼。"
                        splashlog game.id,game,log
                        # 人狼のやつ以外排除
                        game.quantum_patterns=game.quantum_patterns.filter (obj)=>
                            if obj[@id].jobtype=="Diviner"# && obj[@id].dead==false
                                obj[pl.id].jobtype == "Werewolf"
                            else
                                true
                    else
                        log=
                            mode:"skill"
                            to:@id
                            comment:"#{@name} 占卜了 #{pl.name} 的身份，是 村人。"
                        splashlog game.id,game,log
                        # 村人のやつ以外排除
                        game.quantum_patterns=game.quantum_patterns.filter (obj)=>
                            if obj[@id].jobtype=="Diviner"# && obj[@id].dead==false
                                obj[pl.id].jobtype!="Werewolf"
                            else
                                true
                else
                    # 占えない
                    log=
                        mode:"skill"
                        to:@id
                        comment:"#{@name} 已经不可能是占卜师，不能进行占卜。"
                    splashlog game.id,game,log
        if tarobj.Werewolf
            pl=game.getPlayer tarobj.Werewolf
            if pl?
                game.quantum_patterns=game.quantum_patterns.filter (obj)=>
                    # 何番が筆頭かを求める
                    min=Infinity
                    for key,value of obj
                        if value.jobtype=="Werewolf" && value.dead==false && value.rank<min
                            min=value.rank
                    if obj[@id].jobtype=="Werewolf" && obj[@id].rank==min && obj[@id].dead==false
                        # 自己が筆頭人狼
                        if obj[pl.id].jobtype == "Werewolf"# || obj[pl.id].dead==true
                            # 襲えない
                            false
                        else
                            # さらに対応するやつを死亡させる
                            obj[pl.id].dead=true
                            true
                    else
                        true

    isWinner:(game,team)->
        flag=JSON.parse @flag
        unless flag?
            return false

        if flag.Werewolf==1 && team=="Werewolf"
            # 人狼がかったぞ!!!!!
            true
        else if flag.Werewolf==0 && team=="Human"
            # 人类がかったぞ!!!!!
            true
        else
            # よくわからないぞ!
            false
    makejobinfo:(game,result)->
        super
        tarobj=JSON.parse(@target||"{}")
        unless tarobj.Diviner?
            result.open.push "_Quantum_Diviner"
        unless tarobj.Werewolf?
            result.open.push "_Quantum_Werewolf"
        if game.rule.quantumwerewolf_table=="anonymous"
            # 番号がある
            flag=JSON.parse @flag
            result.quantumwerewolf_number=flag.number
    die:(game,found)->
        super
        # 可能性を排除する
        pats=[]
        if found=="punish"
            # 处刑されたときは既に死んでいた可能性を排除
            pats=game.quantum_patterns.filter (obj)=>
                obj[@id].dead==false
        else
            pats=game.quantum_patterns
        if pats.length
            # 1つ選んで职业を决定
            index=Math.floor Math.random()*pats.length
            tjt=pats[index][@id].jobtype
            trk=pats[index][@id].rank
            if trk?
                pats=pats.filter (obj)=>
                    obj[@id].jobtype==tjt && obj[@id].rank==trk
            else
                pats=pats.filter (obj)=>
                    obj[@id].jobtype==tjt

            # ワタシハシンダ
            pats.forEach (obj)=>
                obj[@id].dead=true
        game.quantum_patterns=pats

class RedHood extends Player
    type:"RedHood"
    jobname:"小红帽"
    sleeping:->true
    isReviver:->!@dead || @flag?
    dying:(game,found,from)->
        super
        if found=="werewolf"
            # 狼に襲われた
            # 誰に襲われたか覚えておく
            @setFlag from
        else
            @setFlag null
    deadsunset:(game)->
        if @flag
            w=game.getPlayer @flag
            if w?.dead
                # 殺した狼が死んだ!復活する
                @revive game
    deadsunrise:(game)->
        # 同じ
        @deadsunset game

class Counselor extends Player
    type:"Counselor"
    jobname:"策士"
    sleeping:->true
    jobdone:->@target?
    sunset:(game)->
        @setTarget null
        if game.day==1
            # 一日目はカウンセリングできない
            @setTarget ""
    job:(game,playerid,query)->
        if @target?
            return "已经选择了对象"
        @setTarget playerid
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 尝试了策反 #{pl.name}。"
        splashlog game.id,game,log
        null
    midnight:(game)->
        t=game.getPlayer @target
        return unless t?
        return if t.dead
        if t.isWerewolf() && t.team in ["Werewolf","LoneWolf"]
            # 人狼とか吸血鬼を襲ったら殺される
            @die game,"werewolf2"
            @addGamelog game,"counselKilled",t.type,@target
            return
        if t.isVampire() && t.team=="Vampire"
            @die game,"vampire2"
            @addGamelog game,"counselKilled",t.type,@target
            return
        if t.team!="Human"
            log=
                mode:"skill"
                to:t.id
                comment:"#{t.name} 被策反了。"
            splashlog game.id,game,log
            
            @addGamelog game,"counselSuccess",t.type,@target
            # 複合させる

            newpl=Player.factory null,t,null,Counseled  # カウンセリングされた
            t.transProfile newpl
            t.transform game,newpl,true
        else
            @addGamelog game,"counselFailure",t.type,@target
# 巫女
class Miko extends Player
    type:"Miko"
    jobname:"巫女"
    sleeping:->true
    jobdone:->!!@flag
    job:(game,playerid,query)->
        if @flag
            return "已经使用了能力"
        @setTarget playerid
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 用神圣的力量守护了自己。"
        splashlog game.id,game,log
        @setFlag true
        # その場で変える
        # 複合させる
        pl = game.getPlayer @id

        newpl=Player.factory null,pl,null,MikoProtected # 守られた人
        pl.transProfile newpl
        pl.transform game,newpl,true
        null
    makeJobSelection:(game)->
        # 夜は投票しない
        if game.night
            []
        else super
class GreedyWolf extends Werewolf
    type:"GreedyWolf"
    jobname:"贪婪的狼"
    sleeping:(game)->game.werewolf_target_remain<=0 # 占いは必須ではない
    jobdone:(game)->game.werewolf_target_remain<=0 && (@flag || game.day==1)
    job:(game,playerid,query)->
        if query.jobtype!="GreedyWolf"
            # 人狼の仕事
            return super
        if @flag
            return "已经使用了能力"
        @setFlag true
        if game.werewolf_target_remain+game.werewolf_target.length ==0
            return "今晚不能袭击"
        log=
            mode:"wolfskill"
            comment:"为了满足 #{@name} 的贪欲。人狼们今晚可以多袭击一个人。"
        splashlog game.id,game,log
        game.werewolf_target_remain++
        game.werewolf_flag.push "GreedyWolf_#{@id}"
        game.splashjobinfo game.players.filter (x)=>x.id!=@id && x.isWerewolf()
        null
    makejobinfo:(game,result)->
        super
        if game.night
            if @sleeping game
                # 襲撃は必要ない
                result.open = result.open?.filter (x)=>x!="_Werewolf"
            if !@flag && game.day>=2
                result.open?.push "GreedyWolf"
    makeJobSelection:(game)->
        if game.night && @sleeping(game) && !@jobdone(game)
            # 欲張る选择肢のみある
            return []
        else
            return super
    checkJobValidity:(game,query)->
        if query.jobtype=="GreedyWolf"
            # なしでOK!
            return true
        return super
class FascinatingWolf extends Werewolf
    type:"FascinatingWolf"
    jobname:"魅惑的女狼"
    sleeping:(game)->super && @flag?
    sunset:(game)->
        super
        if @scapegoat && !@flag?
            # 誘惑する
            hus=game.players.filter (x)->!x.dead && !x.isWerewolf()
            if hus.length>0
                r=Math.floor Math.random()*hus.length
                @job game,hus[r].id,{jobtype:"FascinatingWolf"}
            else
                @setFlag ""
    job:(game,playerid,query)->
        if query.jobtype!="FascinatingWolf"
            # 人狼の仕事
            return super
        if @flag
            return "已经使用了能力"
        pl=game.getPlayer playerid
        unless pl?
            return "对象玩家不存在"
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 魅惑了 #{pl.name}。"
        @setFlag playerid
        splashlog game.id,game,log
        null
    dying:(game,found)->
        # 死んだぞーーーーーーーーーーーーーー
        super
        # LWなら変えない
        if game.players.filter((x)->x.isWerewolf() && !x.dead).length==0
            return
        pl=game.getPlayer @flag
        unless pl?
            # あれれーーー
            return
        if pl.dead
            # 既に死んでいた
            return
        unless pl.isHuman() && pl.team!="Werewolf"
            # 誘惑できない
            return

        newpl=Player.factory null,pl,null,WolfMinion    # WolfMinion
        pl.transProfile newpl
        pl.transform game,newpl,true
        log=
            mode:"skill"
            to:pl.id
            comment:"#{pl.name} 被狼魅惑了。"
        splashlog game.id,game,log
    makejobinfo:(game,result)->
        super
        if game.night
            if @flag
                # もう誘惑は必要ない
                result.open = result.open?.filter (x)=>x!="FascinatingWolf"
class SolitudeWolf extends Werewolf
    type:"SolitudeWolf"
    jobname:"孤独的狼"
    sleeping:(game)-> !@flag || super
    isListener:(game,log)->
        if (log.mode in ["werewolf","wolfskill"]) && (log.to != @id)
            # 狼の声は听不到（自己のスキルは除く）
            false
        else super
    job:(game,playerid,query)->
        if !@flag
            return "现在还不能袭击"
        super
    isAttacker:->!@dead && @flag
    sunset:(game)->
        wolves=game.players.filter (x)->x.isWerewolf()
        attackers=wolves.filter (x)->!x.dead && x.isAttacker()
        if !@flag && attackers.length==0
            # 襲えるやつ誰もいない
            @setFlag true
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 现在可以袭击他人了。"
            splashlog game.id,game,log
        else if @flag && attackers.length>1
            # 複数いるのでやめる
            @setFlag false
            log=
                mode:"skill"
                to:@id
                comment:"其他的人狼还活着。#{@name} 现在不能袭击他人。"
            splashlog game.id,game,log
        super
    getSpeakChoice:(game)->
        res=super
        return res.filter (x)->x!="werewolf"
    makejobinfo:(game,result)->
        super
        delete result.wolves
        delete result.spy2s
class ToughWolf extends Werewolf
    type:"ToughWolf"
    jobname:"硬汉人狼"
    job:(game,playerid,query)->
        if query.jobtype!="ToughWolf"
            # 人狼の仕事
            return super
        if @flag
            return "已经使用了能力"
        res=super
        if res?
            return res
        @setFlag true
        game.werewolf_flag.push "ToughWolf_#{@id}"
        tp=game.getPlayer playerid
        unless tp?
            return "这个对象不存在"
        log=
            mode:"wolfskill"
            comment:"#{@name} 抱着舍身的觉悟袭击了 #{tp.name}。"
        splashlog game.id,game,log
        null
class ThreateningWolf extends Werewolf
    type:"ThreateningWolf"
    jobname:"威吓的狼"
    jobdone:(game)->
        if game.night
            super
        else
            @flag?
    chooseJobDay:(game)->true
    sunrise:(game)->
        super
        @setTarget null
    job:(game,playerid,query)->
        if query.jobtype!="ThreateningWolf"
            # 人狼の仕事
            return super
        if @flag
            return "已经使用了能力"
        if game.night
            return "夜晚不能使用能力"
        pl=game.getPlayer playerid
        pl.touched game,@id
        unless pl?
            return "对象无效"
        @setTarget playerid
        @setFlag true
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 威吓了 #{pl.name}。"
        splashlog game.id,game,log
        null
    sunset:(game)->
        t=game.getPlayer @target
        return unless t?
        return if t.dead
            
        # 威嚇して能力無しにする
        @addGamelog game,"threaten",t.type,@target
        # 複合させる

        log=
            mode:"skill"
            to:t.id
            comment:"#{t.name} 受到了威吓。今晚的能力无法发动。"
        splashlog game.id,game,log

        newpl=Player.factory null,t,null,Threatened  # カウンセリングされた
        t.transProfile newpl
        t.transform game,newpl,true

        super
    makejobinfo:(game,result)->
        super
        if game.night
            # 夜は威嚇しない
            result.open = result.open?.filter (x)=>x!="ThreateningWolf"
class HolyMarked extends Human
    type:"HolyMarked"
    jobname:"圣痕者"
class WanderingGuard extends Player
    type:"WanderingGuard"
    jobname:"風来猎人"
    sleeping:->@target?
    sunset:(game)->
        @setTarget null
        if game.day==1
            # 猎人は一日目护卫しない
            @setTarget ""  # 誰も守らない
        else
            fl=JSON.parse(@flag ? "[]")
            alives=game.players.filter (x)->!x.dead
            if alives.every((pl)=>(pl.id in fl) || (game.rule.guardmyself!="ok" && pl.id==@id))
                # もう护卫対象がいない
                @setTarget ""
            else if @scapegoat
                # 身代わり君の自動占い
                r=Math.floor Math.random()*game.players.length
                if @job game,game.players[r].id,{}
                    @sunset game
    job:(game,playerid)->
        fl=JSON.parse(@flag ? "[]")
        if playerid==@id && game.rule.guardmyself!="ok"
            return "不能守护自己"
        
        fl=JSON.parse(@flag ? "[]")
        if playerid in fl
            return "这个人已经不能守护了"
        @setTarget playerid
        # OK!
        pl=game.getPlayer(playerid)
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 守护了 #{pl.name}。"
        splashlog game.id,game,log
        # 複合させる

        newpl=Player.factory null,pl,null,Guarded   # 守られた人
        pl.transProfile newpl
        newpl.cmplFlag=@id  # 护卫元cmplFlag
        pl.transform game,newpl,true
        null
    beforebury:(game,type)->
        if type=="day"
            # 昼になったとき
            if game.players.filter((x)->x.dead && x.found).length==0
                # 誰も死ななかった!护卫できない
                pl=game.getPlayer @target
                if pl?
                    log=
                        mode:"skill"
                        to:@id
                        comment:"#{@name} 不能护卫 #{pl.name}。"
                    splashlog game.id,game,log
                    fl=JSON.parse(@flag ? "[]")
                    fl.push pl.id
                    @setFlag JSON.stringify fl
    makeJobSelection:(game)->
        if game.night
            fl=JSON.parse(@flag ? "[]")
            a=super
            return a.filter (obj)->!(obj.value in fl)
        else
            return super
class ObstructiveMad extends Madman
    type:"ObstructiveMad"
    jobname:"碍事的狂人"
    sleeping:->@target?
    sunset:(game)->
        super
        @setTarget null
        if @scapegoat
            alives=game.players.filter (x)->!x.dead
            if alives.length>0
                r=Math.floor Math.random()*alives.length
                @job game,alives[r].id,{}
            else
                @setTarget ""
    job:(game,playerid)->
        @setTarget playerid
        pl=game.getPlayer playerid
        unless pl?
            return "这个玩家不存在"
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 妨碍了 #{pl.name}。"
        splashlog game.id,game,log
        # 複合させる

        newpl=Player.factory null,pl,null,DivineObstructed
        pl.transProfile newpl
        newpl.cmplFlag=@id  # 邪魔元cmplFlag
        pl.transform game,newpl,true
        null
class TroubleMaker extends Player
    type:"TroubleMaker"
    jobname:"闹事者"
    sleeping:->true
    jobdone:->!!@flag
    makeJobSelection:(game)->
        # 夜は投票しない
        if game.night
            []
        else super
    job:(game,playerid)->
        return "已经使用了能力" if @flag
        @setFlag "using"
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 在村子里引发了混乱。"
        splashlog game.id,game,log
        null
    sunrise:(game)->
        if @flag=="using"
            game.votingbox.addPunishedNumber 1
            # トラブルがおきた
            log=
                mode:"system"
                comment:"闹事者在村子里引发了混乱。今日将会处刑 #{game.votingbox.remains} 个人。"
            splashlog game.id,game,log
            @setFlag "done"
    deadsunrise:(game)->@sunrise game

class FrankensteinsMonster extends Player
    type:"FrankensteinsMonster"
    jobname:"弗兰肯斯坦"
    die:(game,found)->
        super
        if found=="punish"
            # 处刑で死んだらもうひとり处刑できる
            game.votingbox.addPunishedNumber 1
    beforebury:(game)->
        # 新しく死んだひとたちで村人阵营ひとたち
        founds=game.players.filter (x)->x.dead && x.found && x.team=="Human"
        # 吸収する
        thispl=this
        for pl in founds
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 从 #{pl.name} 的尸体里吸收了 #{pl.getJobname()} 的能力。"
            splashlog game.id,game,log

            # 同じ能力を
            subpl = Player.factory pl.type
            thispl.transProfile subpl

            newpl=Player.factory null, thispl,subpl,Complex    # 合成する
            thispl.transProfile newpl

            # 置き換える
            thispl.transform game,newpl,true
            thispl=newpl

            thispl.addGamelog game,"frankeneat",pl.type,pl.id

        if founds.length>0
            game.splashjobinfo [thispl]
class BloodyMary extends Player
    type:"BloodyMary"
    jobname:"血腥玛丽"
    isReviver:->true
    getJobname:->if @flag then @jobname else "玛丽"
    getJobDisp:->@getJobname()
    getTypeDisp:->if @flag then @type else "Mary"
    sleeping:->true
    deadJobdone:(game)->
        if @target?
            true
        else if @flag=="punish"
            !(game.players.some (x)->!x.dead && x.team=="Human")
        else if @flag=="werewolf"
            if game.players.filter((x)->!x.dead && x.isWerewolf()).length>1
                !(game.players.some (x)->!x.dead && x.team in ["Werewolf","LoneWolf"])
            else
                # 狼が残り1匹だと何もない
                true
        else
            true

    dying:(game,found,from)->
        if found in ["punish","werewolf"]
            # 能力が…
            orig_jobname=@getJobname()
            @setFlag found
            if orig_jobname != @getJobname()
                # 変わった!
                @setOriginalJobname @originalJobname.replace("血腥玛丽","玛丽").replace("玛丽","血腥玛丽")
        super
    sunset:(game)->
        @setTarget null
    deadsunset:(game)->
        @sunset game
    job:(game,playerid)->
        unless @flag in ["punish","werewolf"]
            return "不能使用能力"
        pl=game.getPlayer playerid
        unless pl?
            return "对象不存在"
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 诅咒了 #{pl.name}。"
        splashlog game.id,game,log
        @setTarget playerid
        null
    # 呪い殺す!!!!!!!!!
    deadnight:(game)->
        pl=game.getPlayer @target
        unless pl?
            return
        pl.die game,"marycurse",@id
    # 蘇生できない
    revive:->
    isWinner:(game,team)->
        if @flag=="punish"
            team in ["Werewolf","LoneWolf"]
        else
            team==@team
    makeJobSelection:(game)->
        if game.night
            pls=[]
            if @flag=="punish"
                # 村人を……
                pls=game.players.filter (x)->!x.dead && x.team=="Human"
            else if @flag=="werewolf"
                # 人狼を……
                pls=game.players.filter (x)->!x.dead && x.team in ["Werewolf","LoneWolf"]
            return (for pl in pls
                {
                    name:pl.name
                    value:pl.id
                }
            )
        else super
    makejobinfo:(game,obj)->
        super
        if @flag && !("BloodyMary" in obj.open)
            obj.open.push "BloodyMary"

class King extends Player
    type:"King"
    jobname:"国王"
    voteafter:(game,target)->
        super
        game.votingbox.votePower this,1
class PsychoKiller extends Madman
    type:"PsychoKiller"
    jobname:"变态杀人狂"
    constructor:->
        super
        @flag="[]"
    touched:(game,from)->
        # 殺すリストに追加する
        fl=try
               JSON.parse @flag || "[]"
           catch e
               []
        fl.push from
        @setFlag JSON.stringify fl
    sunset:(game)->
        @setFlag "[]"
    midnight:(game)->
        fl=try
               JSON.parse @flag || "[]"
           catch e
               []
        for id in fl
            pl=game.getPlayer id
            if pl? && !pl.dead
                pl.die game,"psycho",@id
        @setFlag "[]"
    deadnight:(game)->
        @midnight game
class SantaClaus extends Player
    type:"SantaClaus"
    jobname:"圣诞老人"
    sleeping:->@target?
    constructor:->
        super
        @setFlag "[]"
    isWinner:(game,team)->@flag=="gone" || super
    sunset:(game)->
        # まだ届けられる人がいるかチェック
        fl=JSON.parse(@flag ? "[]")
        if game.players.some((x)=>!x.dead && x.id!=@id && !(x.id in fl))
            @setTarget null
            if @scapegoat
                cons=game.players.filter((x)=>!x.dead && x.id!=@id && !(x.id in fl))
                if cons.length>0
                    r=Math.floor Math.random()*cons.length
                    @job game,cons[r].id,{}
                else
                    @setTarget ""
        else
            @setTarget ""
    sunrise:(game)->
        # 全员に配ったかチェック
        fl=JSON.parse(@flag ? "[]")
        unless game.players.some((x)=>!x.dead && x.id!=@id && !(x.id in fl))
            # 村を去る
            @setFlag "gone"
            @die game,"spygone"

    job:(game,playerid)->
        if @flag=="gone"
            return "已经离开了村子"
        fl=JSON.parse(@flag ? "[]")
        if playerid == @id
            return "不能把礼物送给自己"
        if playerid in fl
            return "这个人已经不能继续接受礼物了"
        pl=game.getPlayer playerid
        pl.touched game,@id
        unless pl?
            return "对象无效"
        @setTarget playerid
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 向 #{pl.name} 赠送了礼物。"
        splashlog game.id,game,log
        fl.push playerid
        @setFlag JSON.stringify fl
        null
    midnight:(game)->
        return unless @target?
        pl=game.getPlayer @target
        return unless pl?
        return if @flag=="gone"

        # プレゼントを送る
        r=Math.random()
        settype=""
        setname=""
        if r<0.05
            # 毒だった
            log=
                mode:"skill"
                to:pl.id
                comment:"#{pl.name} 收到了剧毒的礼物。"
            splashlog game.id,game,log
            pl.die game,"poison",@id
            @addGamelog game,"sendpresent","poison",pl.id
            return
        else if r<0.1
            settype="HolyMarked"
            setname="圣痕者套装"
        else if r<0.15
            settype="Oldman"
            setname="玉手箱"
        else if r<0.225
            settype="Priest"
            setname="圣职者套装"
        else if r<0.3
            settype="Miko"
            setname="Cosplay套装（巫女）"
        else if r<0.55
            settype="Diviner"
            setname="占卜套装"
        else if r<0.8
            settype="Guard"
            setname="守护套装"
        else
            settype="Psychic"
            setname="灵能套装"

        # 複合させる
        log=
            mode:"skill"
            to:pl.id
            comment:"#{pl.name} 收到了礼物 #{setname}。"
        splashlog game.id,game,log
        
        # 複合させる
        sub=Player.factory settype   # 副を作る
        pl.transProfile sub
        newpl=Player.factory null,pl,sub,Complex    # Complex
        pl.transProfile newpl
        pl.transform game,newpl,true
        @addGamelog game,"sendpresent",settype,pl.id
#怪盗
class Phantom extends Player
    type:"Phantom"
    jobname:"怪盗"
    sleeping:->@target?
    sunset:(game)->
        if @flag==true
            # もう交換済みだ
            @setTarget ""
        else
            @setTarget null
            if @scapegoat
                rs=@makeJobSelection game
                if rs.length>0
                    r=Math.floor Math.random()*rs.length
                    @job game,rs[r].value,{
                        jobtype:@type
                    }
    makeJobSelection:(game)->
        if game.night
            res=[{
                name:"放弃盗取"
                value:""
            }]
            sup=super
            for obj in sup
                pl=game.getPlayer obj.value
                unless pl?.scapegoat
                    res.push obj
            return res
        else
            super
    job:(game,playerid)->
        @setTarget playerid
        if playerid==""
            # 交換しない
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 没有盗取职业。"
            splashlog game.id,game,log
            return
        pl=game.getPlayer playerid
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 盗取了 #{pl.name} 的职业。#{pl.name} 是 #{pl.getJobDisp()}。"
        splashlog game.id,game,log
        @addGamelog game,"phantom",pl.type,playerid
        null
    sunrise:(game)->
        @setFlag true
        pl=game.getPlayer @target
        unless pl?
            return
        savedobj={}
        pl.makejobinfo game,savedobj
        flagobj={}
        # jobinfo表示のみ抜粋
        for value in Shared.game.jobinfos
            if savedobj[value.name]?
                flagobj[value.name]=savedobj[value.name]

        # 自己はそ的职业に変化する
        newpl=Player.factory pl.type
        @transProfile newpl
        @transferData newpl
        @transform game,newpl,false
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 变成了 #{newpl.getJobDisp()}。"
        splashlog game.id,game,log

        # 盗まれた側は怪盗予備軍のフラグを立てる
        newpl2=Player.factory null,pl,null,PhantomStolen
        newpl2.cmplFlag=flagobj
        pl.transProfile newpl2
        pl.transform game,newpl2,true
class BadLady extends Player
    type:"BadLady"
    jobname:"恶女"
    team:"Friend"
    sleeping:->@flag?.set
    sunset:(game)->
        unless @flag?.set
            # まだ恋人未设定
            if @scapegoat
                @flag={
                    set:true
                }
    job:(game,playerid,query)->
        fl=@flag ? {}
        if fl.set
            return "已经决定了对象"
        if playerid==@id
            return "请选择自己以外的对象"
        
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        pl.touched game,@id

        unless fl.main?
            # 本命を決める
            fl.main=playerid
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 选择了 #{pl.name} 作为自己的本命对象。"
            splashlog game.id,game,log
            @setFlag fl
            @addGamelog game,"badlady_main",pl.type,playerid
            return null
        unless fl.keep?
            # キープ相手を決める
            fl.keep=playerid
            fl.set=true
            @setFlag fl
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 选择了 #{pl.name} 作为玩弄的对象。"
            splashlog game.id,game,log
            # 2人を恋人、1人をキープに
            plm=game.getPlayer fl.main
            for pll in [plm,pl]
                if pll?
                    log=
                        mode:"skill"
                        to:pll.id
                        comment:"#{pll.name} 受到求爱变成了恋人。"
                    splashlog game.id,game,log
            # 自己恋人
            newpl=Player.factory null,this,null,Friend # 恋人だ！
            @transProfile newpl
            @transform game,newpl,true  # 入れ替え
            newpl.cmplFlag=fl.main
            # 相手恋人
            newpl=Player.factory null,plm,null,Friend # 恋人だ！
            plm.transProfile newpl
            plm.transform game,newpl,true  # 入れ替え
            newpl.cmplFlag=@id
            # キープ
            newpl=Player.factory null,pl,null,KeepedLover # 恋人か？
            pl.transProfile newpl
            pl.transform game,newpl,true  # 入れ替え
            newpl.cmplFlag=@id
            game.splashjobinfo [@id,plm.id,pl.id].map (id)->game.getPlayer id
            @addGamelog game,"badlady_keep",pl.type,playerid
        null
    makejobinfo:(game,result)->
        super
        if !@jobdone(game) && game.night
            # 夜の选择肢
            fl=@flag ? {}
            unless fl.set
                unless fl.main
                    # 本命を決める
                    result.open.push "BadLady1"
                else if !fl.keep
                    # 手玉に取る
                    result.open.push "BadLady2"
# 看板娘
class DrawGirl extends Player
    type:"DrawGirl"
    jobname:"看板娘"
    sleeping:->true
    dying:(game,found)->
        if found=="werewolf"
            # 狼に噛まれた
            @setFlag "bitten"
        else
            @setFlag ""
        super
    deadsunrise:(game)->
        # 夜明けで死亡していた場合
        if @flag=="bitten"
            # 噛まれて死亡した場合
            game.votingbox.addPunishedNumber 1
            log=
                mode:"system"
                comment:"#{@name} 是看板娘。今日将有 #{game.votingbox.remains} 人被处刑。"
            splashlog game.id,game,log
            @setFlag ""
            @addGamelog game,"drawgirlpower",null,null
# 慎重的狼
class CautiousWolf extends Werewolf
    type:"CautiousWolf"
    jobname:"慎重的狼"
    makeJobSelection:(game)->
        if game.night
            r=super
            return r.concat {
                name:"不袭击"
                value:""
            }
        else
            return super
    job:(game,playerid)->
        if playerid!=""
            super
            return
        # 不袭击場合
        game.werewolf_target.push {
            from:@id
            to:""
        }
        game.werewolf_target_remain--
        log=
            mode:"wolfskill"
            comment:"以 #{@name} 为首的人狼们决定今晚不发动袭击。"
        splashlog game.id,game,log
        game.splashjobinfo game.players.filter (x)=>x.id!=playerid && x.isWerewolf()
        null
# 烟火师
class Pyrotechnist extends Player
    type:"Pyrotechnist"
    jobname:"烟火师"
    sleeping:->true
    jobdone:(game)->@flag? || game.night
    chooseJobDay:(game)->true
    job:(game,playerid,query)->
        if @flag?
            return "已经不能发动能力了"
        if game.night
            return "夜晚不能使用此能力"
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 准备释放烟火了。"
        splashlog game.id,game,log
        # 使用済
        @setFlag "using"
        # 全员花火の虜にしてしまう
        for pl in game.players
            newpl=Player.factory null,pl,null,WatchingFireworks
            pl.transProfile newpl
            newpl.cmplFlag=@id
            pl.transform game,newpl,true
        null
    sunset:(game)->
        if @flag=="using"
            log=
                mode:"system"
                comment:"美丽的烟火被打上了天空。今晚不能使用能力。"
            splashlog game.id,game,log
            @setFlag "done"
    deadsunset:(game)->
        @sunset game
    checkJobValidity:(game,query)->
        if query.jobtype=="Pyrotechnist"
            # 対象选择は不要
            return true
        return super

# 面包店
class Baker extends Player
    type:"Baker"
    jobname:"面包店"
    sleeping:->true
    sunrise:(game)->
        # 最初の1人が面包店ログを管理
        bakers=game.players.filter (x)->x.isJobType "Baker"
        firstBakery=bakers[0]
        if firstBakery?.id==@id
            # わ た し だ
            if bakers.some((x)->!x.dead)
                # 生存面包店がいる
                if @flag=="done"
                    @setFlag null
                log=
                    mode:"system"
                    comment:"面包店烤好了美味的面包。"
                splashlog game.id,game,log
            else if @flag!="done"
                # 全员死亡していてまたログを出していない
                log=
                    mode:"system"
                    comment:"今天开始没有美味的面包吃了。"
                splashlog game.id,game,log
                @setFlag "done"

    deadsunrise:(game)->
        @sunrise game
class Bomber extends Madman
    type:"Bomber"
    jobname:"炸弹魔"
    sleeping:->true
    jobdone:->@flag?
    job:(game,playerid)->
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效。"
        pl.touched game,@id
        @setTarget playerid
        @setFlag true
        # 爆弾を仕掛ける
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 向 #{pl.name} 送出了炸弹。"
        splashlog game.id,game,log

        newpl=Player.factory null,pl,null,BombTrapped
        pl.transProfile newpl
        newpl.cmplFlag=@id  # 护卫元cmplFlag
        pl.transform game,newpl,true

        @addGamelog game,"bomber_set",pl.type,playerid
        null

class Blasphemy extends Player
    type:"Blasphemy"
    jobname:"亵渎者"
    team:"Fox"
    sleeping:(game)->@target? || @flag
    constructor:->
        super
        @setFlag null
    sunset:(game)->
        if @flag
            @setTarget ""
        else
            @setTarget null
            if @scapegoat
                # 替身君
                alives=game.players.filter (x)->!x.dead
                r=Math.floor Math.random()*alives.length
                if @job game,alives[r].id,{}
                    @setTarget ""
    beforebury:(game,type)->
        if @flag
            # まだ狐を作ってないときは耐える
            # 狐が全员死んでいたら自殺
            unless game.players.some((x)->!x.dead && x.isFox())
                @die game,"foxsuicide"
    job:(game,playerid)->
        if @flag || @target?
            return "已经不能发动能力了"
        @setTarget playerid
        pl=game.getPlayer playerid
        unless pl?
            return "这个对象不存在"
        if pl.dead
            return "对象已经死亡"

        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 亵渎了 #{pl.name}。"
        splashlog game.id,game,log

        @addGamelog game,"blasphemy",pl.type,playerid
        return null
    midnight:(game)->
        pl=game.getPlayer @target
        return unless pl?

        # まずい対象だと自己が冒涜される
        if pl.type in ["Fugitive","QueenSpectator","Liar","Spy2","LoneWolf"]
            pl=this
        return if pl.dead
        @setFlag true

        # 狐凭をつける
        newpl=Player.factory null,pl,null,FoxMinion
        pl.transProfile newpl
        pl.transform game,newpl,true

class Ushinotokimairi extends Madman
    type:"Ushinotokimairi"
    jobname:"丑刻参"
    sleeping:->true
    jobdone:->@target?
    sunset:(game)->
        super
        @setTarget null
        if @scapegoat
            alives=game.players.filter (x)->!x.dead
            if alives.length>0
                r=Math.floor Math.random()*alives.length
                if @job game,alives[r].id,{}
                    @setTarget ""
            else
                @setTarget ""

    job:(game,playerid)->
        @setTarget playerid
        pl=game.getPlayer playerid
        unless pl?
            return "这个玩家不存在"
        pl.touched game,@id
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 诅咒了 #{pl.name}。"
        splashlog game.id,game,log
        # 複合させる

        newpl=Player.factory null,pl,null,DivineCursed
        pl.transProfile newpl
        newpl.cmplFlag=@id  # 邪魔元cmplFlag
        pl.transform game,newpl,true

        @addGamelog game,"ushinotokimairi_curse",pl.type,playerid
        null
    divined:(game,player)->
        if @target?
            # 能力を使用していた場合は占われると死ぬ
            @die game,"curse"
            player.addGamelog game,"cursekill",null,@id
        super



# 処理上便宜的に使用
class GameMaster extends Player
    type:"GameMaster"
    jobname:"游戏管理员"
    team:""
    jobdone:->false
    sleeping:->true
    isWinner:(game,team)->null
    # 例外的に昼でも発動する可能性がある
    job:(game,playerid,query)->
        pl=game.getPlayer playerid
        unless pl?
            return "对象无效"
        pl.die game,"gmpunish"
        game.bury("other")
        null
    isListener:(game,log)->true # 全て見える
    getSpeakChoice:(game)->
        pls=for pl in game.players
            "gmreply_#{pl.id}"
        ["gm","gmheaven","gmaudience","gmmonologue"].concat pls
    getSpeakChoiceDay:(game)->@getSpeakChoice game
    chooseJobDay:(game)->true   # 昼でも対象选择

# 帮手
class Helper extends Player
    type:"Helper"
    jobname:"帮手"
    team:""
    jobdone:->@flag?
    sleeping:->true
    voted:(game,votingbox)->true
    isWinner:(game,team)->
        pl=game.getPlayer @flag
        return pl?.isWinner game,team
    # @flag: リッスン対象のid
    # 同じものが見える
    isListener:(game,log)->
        pl=game.getPlayer @flag
        unless pl?
            # 自律行動帮手?
            return super
        if pl.isJobType "Helper"
            # 帮手の帮手の場合は听不到（無限ループ防止）
            return false
        return pl.isListener game,log
    getSpeakChoice:(game)->
        if @flag?
            return ["helperwhisper_#{@flag}"]
        else
            return ["helperwhisper"]
    getSpeakChoiceDay:(game)->@getSpeakChoice game
    job:(game,playerid)->
        if @flag?
            return "已经决定了帮助对象"
        pl=game.getPlayer playerid
        unless pl?
            return "帮助对象不存在"
        @flag=playerid
        log=
            mode:"skill"
            to:playerid
            comment:"#{@name} 成为了 #{pl.name} 的帮手。"
        splashlog game.id,game,log
        # 自己の表記を改める
        game.splashjobinfo [this]
        null

    makejobinfo:(game,result)->
        super
        # ヘルプ先が分かる
        pl=game.getPlayer @flag
        if pl?
            helpedinfo={}
            pl.makejobinfo game,helpedinfo
            result.supporting=pl?.publicinfo()
            result.supportingJob=pl?.getJobDisp()
            for value in Shared.game.jobinfos
                if helpedinfo[value.name]?
                    result[value.name]=helpedinfo[value.name]
        null

# 开始前のやつだ!!!!!!!!
class Waiting extends Player
    type:"Waiting"
    jobname:"尚未分配"
    team:""
    sleeping:(game)->!game.rolerequestingphase || game.rolerequesttable[@id]?
    isListener:(game,log)->
       if log.mode=="audience"
           true
       else super
    getSpeakChoice:(game)->
        return ["prepare"]
    makejobinfo:(game,result)->
        super
        # 自己で追加する
        result.open.push "Waiting"
    makeJobSelection:(game)->
        if game.day==0 && game.rolerequestingphase
            # 开始前
            result=[{
                name:"放弃选择"
                value:""
            }]
            for job,num of game.joblist
                if num
                    result.push {
                        name:Shared.game.getjobname job
                        value:job
                    }
            return result
        else super
    job:(game,target)->
        # 希望职业
        game.rolerequesttable[@id]=target
        if target
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 希望成为 #{Shared.game.getjobname target}。"
        else
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 放弃选择职业。"
        splashlog game.id,game,log
        null
# Endless黑暗火锅でまだ入ってないやつ
class Watching extends Player
    type:"Watching"
    jobname:"观战者"
    team:""
    sleeping:(game)->true
    isWinner:(game,team)->true
    isListener:(game,log)->
       if log.mode in ["audience","inlog"]
           # 参加前なので
           true
       else super
    getSpeakChoice:(game)->
        return ["audience"]
    getSpeakChoiceDay:(game)->
        return ["audience"]

            

# 複合职业 Player.factoryで適切に生成されることを期待
# superはメイン职业 @mainにメイン @subにサブ
# @cmplFlag も持っていい
class Complex
    cmplType:"Complex"  # 複合親そのものの名字
    isComplex:->true
    getJobname:->@main.getJobname()
    getJobDisp:->@main.getJobDisp()

    #@mainのやつを呼ぶ
    mcall:(game,method,args...)->
        if @main.isComplex()
            # そのまま
            return method.apply @main,args
        # 他は親が必要
        top=game.participants.filter((x)=>x.id==@id)[0]
        if top?
            return method.apply top,args
        return null

    setDead:(@dead,@found)->
        @main.setDead @dead,@found
        @sub?.setDead @dead,@found
    setWinner:(@winner)->@main.setWinner @winner
    setTarget:(@target)->@main.setTarget @target
    setFlag:(@flag)->@main.setFlag @flag
    setWill:(@will)->@main.setWill @will
    setOriginalType:(@originalType)->@main.setOriginalType @originalType
    setOriginalJobname:(@originalJobname)->@main.setOriginalJobname @originalJobname
    setNorevive:(@norevive)->@main.setNorevive @norevive

    
    jobdone:(game)-> @mcall(game,@main.jobdone,game) && (!@sub?.jobdone? || @sub.jobdone(game)) # ジョブの場合はサブも考慮
    job:(game,playerid,query)-> # どちらの
        # query.jobtypeがない場合は内部処理なのでmainとして処理する?

        unless query?
            query={}
        unless query.jobtype?
            query.jobtype=@main.type
        if @mcall(game,@main.isJobType,query.jobtype) && !@mcall(game,@main.jobdone,game)
            @mcall game,@main.job,game,playerid,query
        else if @sub?.isJobType?(query.jobtype) && !@sub?.jobdone?(game)
            @sub.job? game,playerid,query
        
    isJobType:(type)->
        @main.isJobType(type) || @sub?.isJobType?(type)
    sunset:(game)->
        @mcall game,@main.sunset,game
        @sub?.sunset? game
    midnight:(game)->
        @mcall game,@main.midnight,game
        @sub?.midnight? game
    deadsunset:(game)->
        @mcall game,@main.deadsunset,game
        @sub?.deadsunset? game
    deadsunrise:(game)->
        @mcall game,@main.deadsunrise,game
        @sub?.deadsunrise? game
    sunrise:(game)->
        @mcall game,@main.sunrise,game
        @sub?.sunrise? game
    votestart:(game)->
        @mcall game,@main.votestart,game
    voted:(game,votingbox)->@mcall game,@main.voted,game,votingbox
    dovote:(game,target)->
        @mcall game,@main.dovote,game,target
    voteafter:(game,target)->
        @mcall game,@main.voteafter,game,target
        @sub?.voteafter game,target
    
    makejobinfo:(game,result)->
        @sub?.makejobinfo? game,result
        @mcall game,@main.makejobinfo,game,result
    beforebury:(game,type)->
        @mcall game,@main.beforebury,game,type
        @sub?.beforebury? game,type
    getjob_target:->
        if @sub?
            @main.getjob_target() | @sub.getjob_target()    # ビットフラグ
        else
            @main.getjob_target()
    die:(game,found,from)->
        @mcall game,@main.die,game,found,from
    dying:(game,found,from)->
        @mcall game,@main.dying,game,found,from
        @sub?.dying game,found,from
    revive:(game)->
        @mcall game,@main.revive,game
        @sub?.revive game
    makeJobSelection:(game)->
        result=@mcall game,@main.makeJobSelection,game
        if @sub?
            for obj in @sub.makeJobSelection game
                unless result.some((x)->x.value==obj.value)
                    result.push obj
        result
    checkJobValidity:(game,query)->
        if query.jobtype=="_day"
            return @mcall(game,@main.checkJobValidity,game,query)
        if @mcall(game,@main.isJobType,query.jobtype) && !@mcall(game,@main.jobdone,game)
            return @mcall(game,@main.checkJobValidity,game,query)
        else if @sub?.isJobType?(query.jobtype) && !@sub?.jobdone?(game)
            return @sub.checkJobValidity game,query
        else
            return true

    getSpeakChoiceDay:(game)->
        result=@mcall game,@main.getSpeakChoiceDay,game
        if @sub?
            for obj in @sub.getSpeakChoiceDay game
                unless result.some((x)->x==obj)
                    result.push obj
        result
    getSpeakChoice:(game)->
        result=@mcall game,@main.getSpeakChoice,game
        if @sub?
            for obj in @sub.getSpeakChoice game
                unless result.some((x)->x==obj)
                    result.push obj
        result
    isListener:(game,log)->
        @mcall(game,@main.isListener,game,log) || @sub?.isListener(game,log)
    isReviver:->@main.isReviver() || @sub?.isReviver()

#superがつかえないので注意
class Friend extends Complex    # 恋人
    # cmplFlag: 相方のid
    cmplType:"Friend"
    isFriend:->true
    team:"Friend"
    getJobname:->"恋人（#{@main.getJobname()}）"
    getJobDisp:->"恋人（#{@main.getJobDisp()}）"
    
    beforebury:(game,type)->
        @mcall game,@main.beforebury,game,type
        @sub?.beforebury? game,type
        ato=false
        if game.rule.friendssplit=="split"
            # 独立
            pl=game.getPlayer @cmplFlag
            if pl? && pl.dead && pl.isFriend()
                ato=true
        else
            # みんな
            friends=game.players.filter (x)->x.isFriend()   #恋人たち
            if friends.length>1 && friends.some((x)->x.dead)
                ato=true
        # 恋人が誰か死んだら自殺
        if ato
            @die game,"friendsuicide"
    makejobinfo:(game,result)->
        @sub?.makejobinfo? game,result
        @mcall game,@main.makejobinfo,game,result
        # 恋人が分かる
        result.desc?.push {
            name:"恋人"
            type:"Friend"
        }
        if game.rule.friendssplit=="split"
            # 独立
            fr=[this,game.getPlayer(@cmplFlag)].filter((x)->x?.isFriend()).map (x)->
                x.publicinfo()
            if Array.isArray result.friends
                result.friends=result.friends.concat fr
            else
                result.friends=fr
        else
            # みんないっしょ
            result.friends=game.players.filter((x)->x.isFriend()).map (x)->
                x.publicinfo()
    isWinner:(game,team)->@team==team && !@dead
    # 相手のIDは?
    getPartner:->
        if @cmplType=="Friend"
            return @cmplFlag
        else
            return @main.getPartner()
# 圣职者にまもられた人
class HolyProtected extends Complex
    # cmplFlag: 护卫元
    cmplType:"HolyProtected"
    die:(game,found)->
        # 一回耐える 死なない代わりに元に戻る
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 被神圣的力量守护了。"
        splashlog game.id,game,log
        game.getPlayer(@cmplFlag).addGamelog game,"holyGJ",found,@id
        
        @uncomplex game
# カルトの信者になった人
class CultMember extends Complex
    cmplType:"CultMember"
    isCult:->true
    getJobname:->"教会信者（#{@main.getJobname()}）"
    getJobDisp:->"教会信者（#{@main.getJobDisp()}）"
    makejobinfo:(game,result)->
        super
        # 信者の説明
        result.desc?.push {
            name:"教会信者"
            type:"CultMember"
        }
# 猎人に守られた人
class Guarded extends Complex
    # cmplFlag: 护卫元ID
    cmplType:"Guarded"
    die:(game,found,from)->
        unless found in ["werewolf","vampire"]
            @mcall game,@main.die,game,found,from
        else
            # 狼に噛まれた場合は耐える
            guard=game.getPlayer @cmplFlag
            if guard?
                guard.addGamelog game,"GJ",null,@id
                if game.rule.gjmessage
                    log=
                        mode:"skill"
                        to:guard.id
                        comment:"#{guard.name} 成功守护了 #{@name}。"
                    splashlog game.id,game,log

    sunrise:(game)->
        # 一日しか守られない
        @sub?.sunrise? game
        @uncomplex game
        @mcall game,@main.sunrise,game
# 黙らされた人
class Muted extends Complex
    cmplType:"Muted"

    sunset:(game)->
        # 一日しか効かない
        @sub?.sunset? game
        @uncomplex game
        @mcall game,@main.sunset,game
        game.ss.publish.user @id,"refresh",{id:game.id}
    getSpeakChoiceDay:(game)->
        ["monologue"]   # 全员に喋ることができない
# 狼的仆从
class WolfMinion extends Complex
    cmplType:"WolfMinion"
    team:"Werewolf"
    getJobname:->"狼的仆从（#{@main.getJobname()}）"
    getJobDisp:->"狼的仆从（#{@main.getJobDisp()}）"
    makejobinfo:(game,result)->
        @sub?.makejobinfo? game,result
        @mcall game,@main.makejobinfo,game,result
        result.desc?.push {
            name:"狼的仆从"
            value:"WolfMinion"
        }
    isWinner:(game,team)->@team==team
# 酒鬼
class Drunk extends Complex
    cmplType:"Drunk"
    getJobname:->"酒鬼（#{@main.getJobname()}）"
    getTypeDisp:->"Human"
    getJobDisp:->"村人"
    sleeping:->true
    jobdone:->true
    isListener:(game,log)->
        Human.prototype.isListener.call @,game,log

    sunset:(game)->
        @mcall game,@main.sunrise,game
        @sub?.sunrise? game
        if game.day>=3
            # 3日目に目が覚める
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 酒醒了。"
            splashlog game.id,game,log
            @uncomplex game
            game.ss.publish.user @realid,"refresh",{id:game.id}
    makejobinfo:(game,obj)->
        Human.prototype.makejobinfo.call @,game,obj
    isDrunk:->true
    getSpeakChoice:(game)->
        Human.prototype.getSpeakChoice.call @,game
# 陷阱师守られた人
class TrapGuarded extends Complex
    # cmplFlag: 护卫元ID
    cmplType:"TrapGuarded"
    midnight:(game)->
        @mcall game,@main.midnight,game
        @sub?.midnight? game
        # 猎人とかぶったら猎人が死んでしまう!!!!!
        # midnight: 狼の襲撃よりも前に行われることが保証されている処理
        wholepl=game.getPlayer @id  # 一番表から見る
        result=@checkGuard game,wholepl
        if result
            # 猎人がいた!（罠も無効）
            @uncomplex game
    # midnight処理用
    checkGuard:(game,pl)->
        return false unless pl.isComplex()
        # Complexの場合:mainとsubを確かめる
        unless pl.cmplType=="Guarded"
            # 見つからない
            result=false
            result ||= @checkGuard game,pl.main
            if pl.sub?
                # 枝を切る
                result ||=@checkGuard game,pl.sub
            return result
        else
            # あった!
            # cmplFlag: 护卫元の猎人
            gu=game.getPlayer pl.cmplFlag
            if gu?
                tr = game.getPlayer @cmplFlag   # 罠し
                if tr?
                    tr.addGamelog game,"trappedGuard",null,@id
                gu.die game,"trap"

            pl.uncomplex game   # 消滅
            # 子の調査を継続
            @checkGuard game,pl.main
            return true

    die:(game,found,from)->
        unless found in ["werewolf","vampire"]
            # 狼以外だとしぬ
            @mcall game,@main.die,game,found
        else
            # 狼に噛まれた場合は耐える
            guard=game.getPlayer @cmplFlag
            if guard?
                guard.addGamelog game,"trapGJ",null,@id
                if game.rule.gjmessage
                    log=
                        mode:"skill"
                        to:guard.id
                        comment:"#{guard.name} 的陷阱成功守护了 #{@name}。"
                    splashlog game.id,game,log
            # 反撃する
            canbedead=[]
            ft=game.getPlayer from
            if ft.isWerewolf()
                canbedead=game.players.filter (x)->!x.dead && x.isWerewolf()
            else if ft.isVampire()
                canbedead=game.players.filter (x)->!x.dead && x.id==from
            return if canbedead.length==0
            r=Math.floor Math.random()*canbedead.length
            pl=canbedead[r] # 被害者
            pl.die game,"trap"
            @addGamelog game,"trapkill",null,pl.id


    sunrise:(game)->
        # 一日しか守られない
        @sub?.sunrise? game
        @uncomplex game
        pl=game.getPlayer @id
        if pl?
            #pl.sunset game
            pl.sunrise game
# 黙らされた人
class Lycanized extends Complex
    cmplType:"Lycanized"
    fortuneResult:"人狼"
    sunset:(game)->
        # 一日しか効かない
        @sub?.sunset? game
        @uncomplex game
        @mcall game,@main.sunset,game
# 策士によって更生させられた人
class Counseled extends Complex
    cmplType:"Counseled"
    team:"Human"
    getJobname:->"更生者（#{@main.getJobname()}）"
    getJobDisp:->"更生者（#{@main.getJobDisp()}）"

    isWinner:(game,team)->@team==team
    makejobinfo:(game,result)->
        @sub?.makejobinfo? game,result
        @mcall game,@main.makejobinfo,game,result
        result.desc?.push {
            name:"更生者"
            type:"Counseled"
        }
# 巫女のガードがある状态
class MikoProtected extends Complex
    cmplType:"MikoProtected"
    die:(game,found)->
        # 耐える
        game.getPlayer(@id).addGamelog game,"mikoGJ",found
    sunset:(game)->
        # 一日しか効かない
        @sub?.sunset? game
        @uncomplex game
        @mcall game,@main.sunset,game
# 威嚇する人狼に威嚇された
class Threatened extends Complex
    cmplType:"Threatened"
    sleeping:->true
    jobdone:->true
    isListener:(game,log)->
        Human.prototype.isListener.call @,game,log

    sunrise:(game)->
        # この昼からは戻る
        @uncomplex game
        pl=game.getPlayer @id
        if pl?
            #pl.sunset game
            pl.sunrise game
    sunset:(game)->
    midnight:(game)->
    job:(game,playerid,query)->
        null
    dying:(game,found,from)->
        Human.prototype.dying.call @,game,found,from
    touched:(game,from)->
    divined:(game,player)->
    voteafter:(game,target)->
    makejobinfo:(game,obj)->
        Human.prototype.makejobinfo.call @,game,obj
    getSpeakChoice:(game)->
        Human.prototype.getSpeakChoice.call @,game
# 碍事的狂人に邪魔された(未完成)
class DivineObstructed extends Complex
    # cmplFlag: 邪魔元ID
    cmplType:"DivineObstructed"
    sunset:(game)->
        # 一日しか守られない
        @sub?.sunrise? game
        @uncomplex game
        @mcall game,@main.sunset,game
    # 占いの影響なし
    divineeffect:(game)->
    showdivineresult:(game)->
        # 结果がでなかった
        pl=game.getPlayer @target
        if pl?
            log=
                mode:"skill"
                to:@id
                comment:"#{@name} 占卜了 #{pl.name} 的身份，但是被不知道什么人妨碍了。"
            splashlog game.id,game,log
    dodivine:(game)->
        # 占おうとした。邪魔成功
        obstmad=game.getPlayer @cmplFlag
        if obstmad?
            obstmad.addGamelog game,"divineObstruct",null,@id
class PhantomStolen extends Complex
    cmplType:"PhantomStolen"
    # cmplFlag: 保存されたアレ
    sunset:(game)->
        # 夜になると怪盗になってしまう!!!!!!!!!!!!
        @sub?.sunrise? game
        newpl=Player.factory "Phantom"
        # アレがなぜか狂ってしまうので一時的に保存
        saved=@originalJobname
        @uncomplex game
        pl=game.getPlayer @id
        pl.transProfile newpl
        pl.transferData newpl
        pl.transform game,newpl,true
        log=
            mode:"skill"
            to:@id
            comment:"#{@name} 的职业被盗走了，变成了 #{newpl.getJobDisp()}。"
        splashlog game.id,game,log
        # 夜の初期化
        pl=game.getPlayer @id
        pl.setOriginalJobname saved
        pl.setFlag true # もう盗めない
        pl.sunset game
    getJobname:->"怪盗" #灵界とかでは既に怪盗化
    # 胜利条件関係は村人化（昼の間だけだし）
    isWerewolf:->false
    isFox:->false
    isVampire:->false
    #team:"Human" #女王との兼ね合いで
    isWinner:(game,team)->
        team=="Human"
    die:(game,found,from)->
        # 抵抗もなく死ぬし
        if found=="punish"
            Player::die.apply this,arguments
        else
            super
    dying:(game,found)->
    makejobinfo:(game,obj)->
        super
        for key,value of @cmplFlag
            obj[key]=value
class KeepedLover extends Complex    # 恶女に手玉にとられた（見た目は恋人）
    # cmplFlag: 相方のid
    cmplType:"KeepedLover"
    getJobname:->"手玉（#{@main.getJobname()}）"
    getJobDisp:->"恋人（#{@main.getJobDisp()}）"
    
    makejobinfo:(game,result)->
        @sub?.makejobinfo? game,result
        @mcall game,@main.makejobinfo,game,result
        # 恋人が分かる
        result.desc?.push {
            name:"恋人"
            type:"Friend"
        }
        # 恋人だと思い込む
        fr=[this,game.getPlayer(@cmplFlag)].map (x)->
            x.publicinfo()
        if Array.isArray result.friends
            result.friends=result.friends.concat fr
        else
            result.friends=fr
# 花火を見ている
class WatchingFireworks extends Complex
    # cmplFlag: 烟火师のid
    cmplType:"WatchingFireworks"
    sleeping:->true
    jobdone:->true

    sunrise:(game)->
        @sub?.sunrise? game
        # もう终了
        @uncomplex game
        pl=game.getPlayer @id
        if pl?
            #pl.sunset game
            pl.sunrise game
    makejobinfo:(game,result)->
        super
        result.watchingfireworks=true
# 炸弹魔に爆弾を仕掛けられた人
class BombTrapped extends Complex
    # cmplFlag: 护卫元ID
    cmplType:"BombTrapped"
    midnight:(game)->
        @mcall game,@main.midnight,game
        @sub?.midnight? game
        # 猎人とかぶったら猎人が死んでしまう!!!!!
        # midnight: 狼の襲撃よりも前に行われることが保証されている処理
        wholepl=game.getPlayer @id  # 一番表から見る
        result=@checkGuard game,wholepl
        if result
            # 猎人がいた!（罠も無効）
            @uncomplex game
    # midnight処理用
    checkGuard:(game,pl)->
        return false unless pl.isComplex()
        # Complexの場合:mainとsubを確かめる
        unless pl.cmplType=="Guarded"
            # 見つからない
            result=false
            result ||= @checkGuard game,pl.main
            if pl.sub?
                # 枝を切る
                result ||=@checkGuard game,pl.sub
            return result
        else
            # あった!
            # cmplFlag: 护卫元の猎人
            gu=game.getPlayer pl.cmplFlag
            if gu?
                tr = game.getPlayer @cmplFlag   #炸弹魔
                if tr?
                    tr.addGamelog game,"bombTrappedGuard",null,@id
                # 护卫元が死ぬ
                gu.die game,"trap"
                # 自己も死ぬ
                @die game,"trap"


            pl.uncomplex game   # 罠は消滅
            # 子の調査を継続
            @checkGuard game,pl.main
            return true

    die:(game,found,from)->
        if found=="punish"
            # 处刑された場合は处刑者の中から選んでしぬ
            # punishのときはfromがidの配列
            if from? && from.length>0
                pls=from.map (id)->game.getPlayer id
                pls=pls.filter (x)->!x.dead
                if pls.length>0
                    r=Math.floor Math.random()*pls.length
                    pl=pls[r]
                    if pl?
                        pl.die game,"trap"
                        @addGamelog game,"bombkill",null,pl.id
        else if found in ["werewolf","vampire"]
            # 狼に噛まれた場合は襲撃者を巻き添えにする
            bomber=game.getPlayer @cmplFlag
            if bomber?
                bomber.addGamelog game,"bompGJ",null,@id
            # 反撃する
            wl=game.getPlayer from
            if wl?
                wl.die game,"trap"
                @addGamelog game,"bombkill",null,wl.id
        # 自己もちゃんと死ぬ
        @mcall game,@main.die,game,found,from

# 狐凭
class FoxMinion extends Complex
    cmplType:"FoxMinion"
    willDieWerewolf:false
    isHuman:->false
    isFox:->true
    isFoxVisible:->true
    getJobname:->"狐凭（#{@main.getJobname()}）"
    # 占われたら死ぬ
    divined:(game,player)->
        @mcall game,@main.divined,game,player
        @die game,"curse"
        player.addGamelog game,"cursekill",null,@id # 呪殺した

# 丑刻参に呪いをかけられた
class DivineCursed extends Complex
    cmplType:"DivineCursed"
    sunset:(game)->
        # 1日で消える
        @uncomplex game
        @mcall game,@main.sunset,game
    divined:(game,player)->
        @mcall game,@main.divined,game,player
        @die game,"curse"
        player.addGamelog game,"cursekill",null,@id # 呪殺した



# 决定者
class Decider extends Complex
    cmplType:"Decider"
    getJobname:->"#{@main.getJobname()}（决定者）"
    dovote:(game,target)->
        result=@mcall game,@main.dovote,game,target
        return result if result?
        game.votingbox.votePriority this,1  #優先度を1上げる
        null
# 权力者
class Authority extends Complex
    cmplType:"Authority"
    getJobname:->"#{@main.getJobname()}（权力者）"
    dovote:(game,target)->
        result=@mcall game,@main.dovote,game,target
        return result if result?
        game.votingbox.votePower this,1 #票をひとつ増やす
        null
games={}

# 游戏のGC
new cron.CronJob '0 0 * * * *',()->
    # いらないGameを消す
    tm=Date.now()-3600000   # 1时间前
    for id,game of games
        if game.finished
            # 終わっているやつが消す候補
            l=game.logs[game.logs.length-1]
            if (!l?) || (l.time<tm)
                # 十分古い
                delete games[id]


# 游戏を得る
getGame=(id)->

# 仕事一览
jobs=
    Human:Human
    Werewolf:Werewolf
    Diviner:Diviner
    Psychic:Psychic
    Madman:Madman
    Guard:Guard
    Couple:Couple
    Fox:Fox
    Poisoner:Poisoner
    BigWolf:BigWolf
    TinyFox:TinyFox
    Bat:Bat
    Noble:Noble
    Slave:Slave
    Magician:Magician
    Spy:Spy
    WolfDiviner:WolfDiviner
    Fugitive:Fugitive
    Merchant:Merchant
    QueenSpectator:QueenSpectator
    MadWolf:MadWolf
    Neet:Neet
    Liar:Liar
    Spy2:Spy2
    Copier:Copier
    Light:Light
    Fanatic:Fanatic
    Immoral:Immoral
    Devil:Devil
    ToughGuy:ToughGuy
    Cupid:Cupid
    Stalker:Stalker
    Cursed:Cursed
    ApprenticeSeer:ApprenticeSeer
    Diseased:Diseased
    Spellcaster:Spellcaster
    Lycan:Lycan
    Priest:Priest
    Prince:Prince
    PI:PI
    Sorcerer:Sorcerer
    Doppleganger:Doppleganger
    CultLeader:CultLeader
    Vampire:Vampire
    LoneWolf:LoneWolf
    Cat:Cat
    Witch:Witch
    Oldman:Oldman
    Tanner:Tanner
    OccultMania:OccultMania
    MinionSelector:MinionSelector
    WolfCub:WolfCub
    WhisperingMad:WhisperingMad
    Lover:Lover
    Thief:Thief
    Dog:Dog
    Dictator:Dictator
    SeersMama:SeersMama
    Trapper:Trapper
    WolfBoy:WolfBoy
    Hoodlum:Hoodlum
    QuantumPlayer:QuantumPlayer
    RedHood:RedHood
    Counselor:Counselor
    Miko:Miko
    GreedyWolf:GreedyWolf
    FascinatingWolf:FascinatingWolf
    SolitudeWolf:SolitudeWolf
    ToughWolf:ToughWolf
    ThreateningWolf:ThreateningWolf
    HolyMarked:HolyMarked
    WanderingGuard:WanderingGuard
    ObstructiveMad:ObstructiveMad
    TroubleMaker:TroubleMaker
    FrankensteinsMonster:FrankensteinsMonster
    BloodyMary:BloodyMary
    King:King
    PsychoKiller:PsychoKiller
    SantaClaus:SantaClaus
    Phantom:Phantom
    BadLady:BadLady
    DrawGirl:DrawGirl
    CautiousWolf:CautiousWolf
    Pyrotechnist:Pyrotechnist
    Baker:Baker
    Bomber:Bomber
    Blasphemy:Blasphemy
    Ushinotokimairi:Ushinotokimairi
    # 特殊
    GameMaster:GameMaster
    Helper:Helper
    # 开始前
    Waiting:Waiting
    Watching:Watching
    
complexes=
    Complex:Complex
    Friend:Friend
    HolyProtected:HolyProtected
    CultMember:CultMember
    Guarded:Guarded
    Muted:Muted
    WolfMinion:WolfMinion
    Drunk:Drunk
    Decider:Decider
    Authority:Authority
    TrapGuarded:TrapGuarded
    Lycanized:Lycanized
    Counseled:Counseled
    MikoProtected:MikoProtected
    Threatened:Threatened
    DivineObstructed:DivineObstructed
    PhantomStolen:PhantomStolen
    KeepedLover:KeepedLover
    WatchingFireworks:WatchingFireworks
    BombTrapped:BombTrapped
    FoxMinion:FoxMinion
    DivineCursed:DivineCursed

    # 职业ごとの強さ
jobStrength=
    Human:5
    Werewolf:40
    Diviner:25
    Psychic:15
    Madman:10
    Guard:23
    Couple:10
    Fox:25
    Poisoner:20
    BigWolf:80
    TinyFox:10
    Bat:10
    Noble:12
    Slave:5
    Magician:14
    Spy:14
    WolfDiviner:60
    Fugitive:8
    Merchant:18
    QueenSpectator:20
    MadWolf:40
    Neet:50
    Liar:8
    Spy2:5
    Copier:10
    Light:30
    Fanatic:20
    Immoral:5
    Devil:20
    ToughGuy:11
    Cupid:37
    Stalker:10
    Cursed:2
    ApprenticeSeer:23
    Diseased:16
    Spellcaster:6
    Lycan:5
    Priest:17
    Prince:17
    PI:23
    Sorcerer:14
    Doppleganger:15
    CultLeader:10
    Vampire:40
    LoneWolf:28
    Cat:22
    Witch:23
    Oldman:4
    Tanner:15
    OccultMania:10
    MinionSelector:0
    WolfCub:70
    WhisperingMad:20
    Lover:25
    Thief:0
    Dog:7
    Dictator:18
    SeersMama:15
    Trapper:13
    WolfBoy:11
    Hoodlum:5
    QuantumPlayer:0
    RedHood:16
    Counselor:25
    Miko:14
    GreedyWolf:60
    FascinatingWolf:52
    SolitudeWolf:20
    ToughWolf:55
    ThreateningWolf:50
    HolyMarked:6
    WanderingGuard:10
    ObstructiveMad:19
    TroubleMaker:15
    FrankensteinsMonster:50
    BloodyMary:5
    King:15
    PsychoKiller:25
    SantaClaus:20
    Phantom:15
    BadLady:30
    DrawGirl:10
    CautiousWolf:45
    Pyrotechnist:20
    Baker:16
    Bomber:23
    Blasphemy:10
    Ushinotokimairi:19

module.exports.actions=(req,res,ss)->
    req.use 'session'

#游戏开始処理
#成功：null
    gameStart:(roomid,query)->
        game=games[roomid]
        unless game?
            res "游戏不存在"
            return
        Server.game.rooms.oneRoomS roomid,(room)->
            if room.error?
                res room.error
                return
            unless room.mode=="waiting"
                # すでに开始している
                res "本场游戏已经开始"
                return
            if room.players.some((x)->!x.start)
                res "全员尚未全部准备好"
                return
            # 规则オブジェクト用意
            ruleobj={
                number: room.players.length
                maxnumber:room.number
                blind:room.blind
                gm:room.gm
                day: parseInt(query.day_minute)*60+parseInt(query.day_second)
                night: parseInt(query.night_minute)*60+parseInt(query.night_second)
                remain: parseInt(query.remain_minute)*60+parseInt(query.remain_second)
                # (n=15)秒规则
                silentrule: parseInt(query.silentrule) ? 0
            }
            
            options={}  # 选项ズ
            for opt in ["decider","authority"]
                options[opt]=query[opt] ? null

            joblist={}
            for job of jobs
                joblist[job]=0  # 一旦初期化
            #frees=room.players.length  # 参加者の数
            # プレイヤーと其他に分類
            players=[]
            supporters=[]
            for pl in room.players
                if pl.mode=="player"
                    players.push pl
                else
                    supporters.push pl
            frees=players.length
            if query.scapegoat=="on"    # 替身君
                frees++
            playersnumber=frees
            # 人数の確認
            if frees<6
                res "人数不足，不能开始。"
                return
            if query.jobrule=="特殊规则.量子人狼" && frees>=20
                # 多すぎてたえられない
                res "人数过多。量子人狼的人数应当在19人以下。"
                return
                
            ruleinfo_str="" # 开始告知

            if query.jobrule in ["特殊规则.自由配置","特殊规则.半份黑暗火锅"]   # 自由のときはクエリを参考にする
                for job in Shared.game.jobs
                    joblist[job]=parseInt(query[job]) || 0    # 仕事の数
                # カテゴリも
                for type of Shared.game.categoryNames
                    joblist["category_#{type}"]=parseInt(query["category_#{type}"]) || 0
                ruleinfo_str = Shared.game.getrulestr query.jobrule,joblist
            if query.jobrule in ["特殊规则.黑暗火锅","特殊规则.半份黑暗火锅","特殊规则.Endless黑暗火锅"]
                # カテゴリ内の人数の合計がわかる関数
                countCategory=(categoryname)->
                    Shared.game.categories[categoryname].reduce(((prev,curr)->prev+(joblist[curr] ? 0)),0)+joblist["category_#{categoryname}"]

                # 黑暗火锅のときはランダムに決める
                pls=frees   # プレイヤーの数をとっておく
                plsh=Math.floor pls/2   # 過半数
        
                if query.jobrule=="特殊规则.半份黑暗火锅"
                    # 半份黑暗火锅のときは村人のみ黑暗火锅
                    frees=joblist.Human ? 0
                    joblist.Human=0
                ruleinfo_str = Shared.game.getrulestr query.jobrule,joblist

                safety={
                    jingais:false   # 人外の数を調整
                    teams:false     # 阵营の数を調整
                    jobs:false      # 職どうしの数を調整
                    strength:false  # 職の強さも考慮
                    reverse:false   # 職の強さが逆
                }
                switch query.yaminabe_safety
                    when "low"
                        # 低い
                        safety.jingais=true
                    when "middle"
                        safety.jingais=true
                        safety.teams=true
                    when "high"
                        safety.jingais=true
                        safety.teams=true
                        safety.jobs=true
                    when "super"
                        safety.jingais=true
                        safety.teams=true
                        safety.jobs=true
                        safety.strength=true
                    when "supersuper"
                        safety.jobs=true
                        safety.strength=true
                    when "reverse"
                        safety.jingais=true
                        safety.strength=true
                        safety.reverse=true


                # 黑暗火锅のときは入れないのがある
                exceptions=["MinionSelector","Thief","GameMaster","Helper","QuantumPlayer","Waiting","Watching"]
                options.yaminabe_hidejobs=query.yaminabe_hidejobs ? null
                if query.yaminabe_hidejobs=="" || !safety.jobs
                    exceptions.push "BloodyMary"
                unless query.jobrule=="特殊规则.半份黑暗火锅" && countCategory("Werewolf")>0
                    #人外の数
                    if safety.jingais
                        # いい感じに決めてあげる
                        wolf_number=1
                        fox_number=0
                        vampire_number=0
                        devil_number=0
                        if frees>=9
                            wolf_number++
                            if frees>=12
                                if Math.random()<0.6
                                    fox_number++
                                else if Math.random()<0.7
                                    devil_number++
                                if frees>=14
                                    wolf_number++
                                    if frees>=16
                                        if Math.random()<0.5
                                            fox_number++
                                        else if Math.random()<0.3
                                            vampire_number++
                                        else
                                            devil_number++
                                        if frees>=18
                                            wolf_number++
                                            if frees>=22
                                                if Math.random()<0.2
                                                    fox_number++
                                                else if Math.random()<0.6
                                                    vampire_number++
                                                else if Math.random()<0.9
                                                    devil_number++
                                            if frees>=24
                                                wolf_number++
                                                if frees>=30
                                                    wolf_number++
                        # ランダム調整
                        if wolf_number>1 && Math.random()<0.1
                            wolf_number--
                        else if frees>0 && playersnumber>=10 && Math.random()<0.2
                            wolf_number++
                        if fox_number>1 && Math.random()<0.15
                            fox_number--
                        else if frees>=11 && Math.random()<0.25
                            fox_number++
                        else if frees>=8 && Math.random()<0.1
                            fox_number++
                        if frees>=11 && Math.random()<0.2
                            vampire_number++
                        if frees>=11 && Math.random()<0.2
                            devil_number++
                        # セットする
                        if joblist.category_Werewolf>0
                            frees+=joblist.category_Werewolf
                        joblist.category_Werewolf=wolf_number
                        if joblist.Fox>0
                            frees+=joblist.Fox
                        if joblist.TinyFox>0
                            frees+=joblist.TinyFox
                        if joblist.Blasphemy>0
                            frees+=joblist.Blasphemy
                        joblist.Fox=0
                        joblist.TinyFox=0
                        joblist.Blasphemy=0

                        # 狐を振分け
                        for i in [0...fox_number]
                            r = Math.random()
                            if r<0.55
                                joblist.Fox++
                            else if r<0.85
                                joblist.TinyFox++
                            else
                                joblist.Blasphemy++
                        if joblist.Vampire>0
                            frees+=joblist.Vampire
                        joblist.Vampire=vampire_number
                        if joblist.Devil>0
                            frees+=joblist.Devil
                        joblist.Devil=devil_number
                        frees-= wolf_number+fox_number+vampire_number+devil_number
                        # 人外は選んだのでもう選ばれなくする
                        exceptions=exceptions.concat Shared.game.nonhumans
                        exceptions.push "Blasphemy"
                    else
                        # 調整しない
                        joblist.category_Werewolf=1
                        frees--
                
                if safety.jingais || safety.jobs
                    if joblist.Fox==0 && joblist.TinyFox==0
                        exceptions.push "Immoral"   # 狐がいないのに背徳は出ない
                    

                if safety.teams
                    # 阵营調整もする
                    # 恋人阵营
                    if frees>0
                        if 17>=playersnumber>=12
                            if Math.random()<0.15
                                joblist.Cupid++
                                frees--
                            else if Math.random()<0.12
                                joblist.Lover++
                                frees--
                            else if Math.random()<0.1
                                joblist.BadLady++
                                frees--
                        else if playersnumber>=8
                            if Math.random()<0.15
                                joblist.Lover++
                                frees--
                            else if Math.random()<0.1
                                joblist.Cupid++
                                frees--
                    exceptions.push "Cupid","Lover","BadLady"
                    # 妖狐阵营
                    if frees>0 && joblist.Fox>0
                        if joblist.Fox==1
                            if playersnumber>=14
                                # 1人くらいは…
                                if Math.random()<0.3
                                    joblist.Immoral++
                                    frees--
                            else
                                # サプライズ的に…
                                if Math.random()<0.1
                                    joblist.Immoral++
                                    frees--
                            exceptions.push "Immoral"
                    # 人狼阵营
                    if frees>0
                        wolf_number = countCategory "Werewolf"
                        if wolf_number<=playersnumber/8
                            # 確定狂人サービス
                            joblist.category_Madman ?= 0
                            joblist.category_Madman++
                            frees--
                # 占い確定
                if safety.teams || safety.jobs
                    # 村人阵营
                    if frees>0
                        # 占卜师いてほしい
                        if Math.random()<0.8
                            joblist.Diviner++
                            frees--
                        else if !safety.jobs && Math.random()<0.3
                            joblist.ApprenticeSeer++
                            frees--
                if safety.teams
                    # できれば猎人も
                    if frees>0
                        if joblist.Diviner>0
                            if Math.random()<0.5
                                joblist.Guard++
                                frees--
                        else if Math.random()<0.2
                            joblist.Guard++
                            frees--
                ((date)->
                    month=date.getMonth()
                    d=date.getDate()
                    if month==11 && 24<=d<=25
                        # 12/24〜12/25はサンタがよくでる
                        if Math.random()<0.5 && frees>0
                            joblist.SantaClaus ?= 0
                            joblist.SantaClaus++
                            frees--
                    else
                        # サンタは出にくい
                        if Math.random()<0.8
                            exceptions.push "SantaClaus"
                    unless month==6 && 26<=d || month==7 && d<=16
                        # 期間外は烟火师は出にくい
                        if Math.random()<0.7
                            exceptions.push "Pyrotechnist"
                    else
                        # ちょっと出やすい
                        if Math.random()<0.11 && frees>0
                            joblist.Pyrotechnist ?= 0
                            joblist.Pyrotechnist++
                            frees--
                    if month==11 && 24<=d<=25 || month==1 && d==14
                        # 炸弹魔がでやすい
                        if Math.random()<0.5 && frees>0
                            joblist.Bomber ?= 0
                            joblist.Bomber++
                            frees--
                    if month==0 && d<=3
                        # 正月は巫女がでやすい
                        if Math.random()<0.5 && frees>0
                            joblist.Miko ?= 0
                            joblist.Miko++
                            frees--
                    if month==3 && d==1
                        # 4月1日は骗子がでやすい
                        if Math.random()<0.5
                            while frees>0
                                joblist.Liar ?= 0
                                joblist.Liar++
                                frees--
                                if Math.random()<0.75
                                    break

                )(new Date)
                
                possibility=Object.keys(jobs).filter (x)->!(x in exceptions)
                
            
                # 強制的に入れる関数
                init=(jobname,categoryname)->
                    unless jobname in possibility
                        return false
                    if categoryname? && joblist["category_#{categoryname}"]>0
                        # あった
                        joblist[jobname]++
                        joblist["category_#{categoryname}"]--
                        return true
                    if frees>0
                        # あった
                        joblist[jobname]++
                        frees--
                        return true
                    return false

                # 安全性超用
                trial_count=0
                trial_max=if safety.strength then 40 else 1
                best_list=null
                best_points=null
                if safety.reverse
                    best_diff=-Infinity
                else
                    best_diff=Infinity
                first_list=joblist
                first_frees=frees
                # チームのやつキャッシュ
                teamCache={}
                getTeam=(job)->
                    if teamCache[job]?
                        return teamCache[job]
                    for team of Shared.game.teams
                        if job in Shared.game.teams[team]
                            teamCache[job]=team
                            return team
                    return null
                while trial_count++ < trial_max
                    joblist=copyObject first_list
                    #wolf_teams=countCategory "Werewolf"
                    wolf_teams=0
                    frees=first_frees
                    while true
                        category=null
                        job=null
                        #カテゴリ职业がまだあるか探す
                        for type,arr of Shared.game.categories
                            if joblist["category_#{type}"]>0
                                r=Math.floor Math.random()*arr.length
                                job=arr[r]
                                category="category_#{type}"
                                break
                        unless job?
                            # もうカテゴリがない
                            if frees<=0
                                # もう空きがない
                                break
                            r=Math.floor Math.random()*possibility.length
                            job=possibility[r]
                        if safety.teams && !category?
                            if job in Shared.game.teams.Werewolf
                                if wolf_teams+1>=plsh
                                    # 人狼が過半数を越えた（PP）
                                    continue
                        if safety.jobs
                            # 職どうしの兼ね合いを考慮
                            switch job
                                when "Psychic","RedHood"
                                    # 1人のとき灵能は意味ない
                                    if countCategory("Werewolf")==1
                                        # 狼1人だと灵能が意味ない
                                        continue
                                when "Couple"
                                    # 共有者はひとりだと寂しい
                                    if joblist.Couple==0
                                        unless init "Couple","Human"
                                            #共有者が入る隙間はない
                                            continue
                                when "Noble"
                                    # 贵族は奴隶がほしい
                                    if joblist.Slave==0
                                        unless init "Slave","Human"
                                            continue
                                when "Slave"
                                    if joblist.Noble==0
                                        unless init "Noble","Human"
                                            continue
                                when "OccultMania"
                                    if joblist.Diviner==0 && Math.random()<0.5
                                        # 占卜师いないと出现確率低い
                                        continue
                                when "QueenSpectator"
                                    # 2人いたらだめ
                                    if joblist.QueenSpectator>0 || joblist.Spy2>0 || joblist.BloodyMary>0
                                        continue
                                    if Math.random()>0.1
                                        # 90%の確率で弾く
                                        continue
                                    # 女王观战者はガードがないと不安
                                    if joblist.Guard==0 && joblist.Priest==0 && joblist.Trapper==0
                                        unless Math.random()<0.4 && init "Guard","Human"
                                            unless Math.random()<0.5 && init "Priest","Human"
                                                unless init "Trapper","Human"
                                                    # 护卫がいない
                                                    continue
                                when "Spy2"
                                    # 间谍IIは2人いるとかわいそうなので入れない
                                    if joblist.Spy2>0 || joblist.QueenSpectator>0
                                        continue
                                    else if Math.random()>0.1
                                        # 90%の確率で弾く（レア）
                                        continue
                                when "MadWolf"
                                    if Math.random()>0.1
                                        # 90%の確率で弾く（レア）
                                        continue
                                when "Lycan","SeersMama","Sorcerer","WolfBoy","ObstructirveMad"
                                    # 占い系がいないと入れない
                                    if joblist.Diviner==0 && joblist.ApprenticeSeer==0 && joblist.PI==0
                                        continue
                                when "LoneWolf","FascinatingWolf","ToughWolf","WolfCub"
                                    # 魅惑的女狼はほかに人狼がいないと効果発揮しない
                                    # 硬汉人狼はほかに狼いないと微妙、一匹狼は1人だけででると狂人が絶望
                                    if countCategory("Werewolf")-(if category? then 1 else 0)==0
                                        continue
                                when "BigWolf"
                                    # 強いので狼2以上
                                    if countCategory("Werewolf")-(if category? then 1 else 0)==0
                                        continue
                                    # 灵能を出す
                                    unless Math.random()<0.15 ||  init "Psychic","Human"
                                        continue
                                when "BloodyMary"
                                    # 狼が2以上必要
                                    if countCategory("Werewolf")<=1
                                        continue
                                    # 女王とは共存できない
                                    if joblist.QueenSpectator>0
                                        continue

                        joblist[job]++
                        # ひとつ追加
                        if category?
                            joblist[category]--
                        else
                            frees--

                        if safety.teams && (job in Shared.game.teams.Werewolf)
                            wolf_teams++    # 人狼阵营が増えた
                    # 安全性超の場合判定が入る
                    if safety.strength
                        # ポイントを計算する
                        points=
                            Human:0
                            Werewolf:0
                            Others:0
                        for job of jobStrength
                            if joblist[job]>0
                                switch getTeam(job)
                                    when "Human"
                                        points.Human+=jobStrength[job]*joblist[job]
                                    when "Werewolf"
                                        points.Werewolf+=jobStrength[job]*joblist[job]
                                    else
                                        points.Others+=jobStrength[job]*joblist[job]
                        # 判定する
                        if points.Others>points.Human || points.Others>points.Werewolf
                            # だめだめ
                            continue
                        # jgs=Math.sqrt(points.Werewolf*points.Werewolf+points.Others*points.Others)
                        jgs = points.Werewolf+points.Others
                        diff=Math.abs(points.Human-jgs)
                        if safety.reverse
                            # 逆
                            diff+=points.Others
                            if diff>best_diff
                                best_list=copyObject joblist
                                best_diff=diff
                                best_points=points
                        else
                            if diff<best_diff
                                best_list=copyObject joblist
                                best_diff=diff
                                best_points=points
                                #console.log "diff:#{diff}"
                                #console.log best_list

                if safety.strength && best_list?
                    # 安全性超
                    joblist=best_list

                if (joblist.WolfBoy>0 || joblist.ObstructiveMad>0) && query.divineresult=="immediate"
                    query.divineresult="sunrise"
                    log=
                        mode:"system"
                        comment:"由于存在能够左右占卜结果的职业，占卜结果从「立刻知道」变更为「天亮才知道」。"
                    splashlog game.id,game,log



            else if query.jobrule=="特殊规则.量子人狼"
                # 量子人狼のときは全员量子人类だけど职业はある
                func=Shared.game.getrulefunc "内部利用.量子人狼"
                joblist=func frees
                sum=0
                for job of jobs
                    if joblist[job]
                        sum+=joblist[job]
                joblist.Human=frees-sum # 残りは村人だ!
                list_for_rule = JSON.parse JSON.stringify joblist
                ruleobj.quantum_joblist=joblist
                # 人狼の順位を決めていく
                i=1
                while joblist.Werewolf>0
                    joblist["Werewolf#{i}"]=1
                    joblist.Werewolf-=1
                    i+=1
                delete joblist.Werewolf
                # 量子人狼用
                joblist={
                    QuantumPlayer:frees
                }
                for job of jobs
                    unless joblist[job]?
                        joblist[job]=0
                ruleinfo_str=Shared.game.getrulestr query.jobrule,list_for_rule
                

            else if query.jobrule!="特殊规则.自由配置"
                # 配置に従ってアレする
                func=Shared.game.getrulefunc query.jobrule
                unless func
                    res "不明的配置"
                    return
                joblist=func frees
                sum=0   # 穴を埋めつつ合計数える
                for job of jobs
                    unless joblist[job]?
                        joblist[job]=0
                    else
                        sum+=joblist[job]
                # カテゴリも
                for type of Shared.game.categoryNames
                    if joblist["category_#{type}"]>0
                        sum-=parseInt joblist["category_#{type}"]
                joblist.Human=frees-sum # 残りは村人だ!
                ruleinfo_str=Shared.game.getrulestr query.jobrule,joblist
                
            log=
                mode:"system"
                comment:"配置: #{ruleinfo_str}"
            splashlog game.id,game,log
            
            if query.jobrule in ["特殊规则.黑暗火锅","特殊规则.半份黑暗火锅","特殊规则.Endless黑暗火锅"]
                if query.yaminabe_hidejobs==""
                    # 职业は公開される
                    jobinfos=[]
                    for job,num of joblist
                        continue if num==0
                        jobinfos.push "#{Shared.game.getjobname job}#{num}"
                    log=
                        mode:"system"
                        comment:"出场职业: "+jobinfos.join(" ")
                    splashlog game.id,game,log
                else if query.yaminabe_hidejobs=="team"
                    # 阵营のみ公開
                    # 各阵营
                    teaminfos=[]
                    console.log game.id,joblist
                    for team,obj of Shared.game.jobinfo
                        teamcount=0
                        for job,num of joblist
                            #出现职业チェック
                            continue if num==0
                            if obj[job]?
                                # この阵营だ
                                teamcount+=num
                        if teamcount>0
                            teaminfos.push "#{obj.name}#{teamcount}"    #阵营名

                    log=
                        mode:"system"
                        comment:"出场阵营信息: "+teaminfos.join(" ")
                    splashlog game.id,game,log

            
            for x in ["jobrule",
            "decider","authority","scapegoat","will","wolfsound","couplesound","heavenview",
            "wolfattack","guardmyself","votemyself","deadfox","deathnote","divineresult","psychicresult","waitingnight",
            "safety","friendsjudge","noticebitten","voteresult","GMpsychic","wolfminion","drunk","losemode","gjmessage","rolerequest","runoff",
            "friendssplit",
            "quantumwerewolf_table","quantumwerewolf_dead","quantumwerewolf_diviner","quantumwerewolf_firstattack","yaminabe_hidejobs","yaminabe_safety"]
            
                ruleobj[x]=query[x] ? null

            game.setrule ruleobj
            # 配置リストをセット
            game.joblist=joblist
            game.startoptions=options
            game.startplayers=players
            game.startsupporters=supporters
            
            if ruleobj.rolerequest=="on" && !(query.jobrule in ["特殊规则.黑暗火锅","特殊规则.半份黑暗火锅","特殊规则.量子人狼","特殊规则.Endless黑暗火锅"])
                # 希望役职制あり
                # とりあえず入れなくする
                M.rooms.update {id:roomid},{$set:{mode:"playing"}}
                # 职业选择中
                game.rolerequestingphase=true
                # ここ書いてないよ!
                game.rolerequesttable={}
                res null
                log=
                    mode:"system"
                    comment:"本场游戏采取了希望役职制，请选择希望就职的职业。"
                splashlog game.id,game,log
                game.timer()
                ss.publish.channel "room#{roomid}","refresh",{id:roomid}
            else
                game.setplayers (result)->
                    unless result?
                        # プレイヤー初期化に成功
                        M.rooms.update {id:roomid},{
                            $set:{
                                mode:"playing",
                                jobrule:query.jobrule
                            }
                        }
                        game.nextturn()
                        res null
                        ss.publish.channel "room#{roomid}","refresh",{id:roomid}
                    else
                        res result
    # 情報を開示
    getlog:(roomid)->
        game=games[roomid]
        ne= =>
            # 游戏後の行動
            player=game.getPlayerReal req.session.userId
            result=
                #logs:game.logs.filter (x)-> islogOK game,player,x
                logs:game.makelogs player
            result=makejobinfo game,player,result
            result.timer=if game.timerid?
                game.timer_remain-(Date.now()/1000-game.timer_start)    # 全体 - 経過时间
            else
                null
            result.timer_mode=game.timer_mode
            if game.day==0
                # 开始前はプレイヤー情報配信しない
                delete result.game.players
            res result
        if game?
            ne()
        else
            # DBから読もうとする
            M.games.findOne {id:roomid}, (err,doc)=>
                if err?
                    console.log err
                    throw err
                unless doc?
                    res {error:"游戏不存在"}
                    return
                games[roomid]=game=Game.unserialize doc,ss
                ne()
            return
        
    speak: (roomid,query)->
        game=games[roomid]
        unless game?
            res "游戏不存在"
            return
        unless req.session.userId
            res "请登陆"
            return
        unless query?
            res "无效操作"
            return
        comment=query.comment
        unless comment
            res "没有简介"
            return
        player=game.getPlayerReal req.session.userId
        #console.log query,player
        log =
            comment:comment
            userid:req.session.userId
            name:player?.name ? req.session.user.name
            to:null
        if query.size in ["big","small"]
            log.size=query.size
        # ログを流す
        dosp=->
            
            if !game.finished  && game.voting   # 投票犹豫时间は发言できない
                if player && !player.dead && !player.isJobType("GameMaster")
                    return  #まだ死んでいないプレイヤーの場合は发言できないよ!
            if game.day<=0 || game.finished #準備中
                unless log.mode=="audience"
                    log.mode="prepare"
                if player?.isJobType "GameMaster"
                    log.mode="gm"
                    #log.name="游戏管理员"
            else
                # 游戏している
                unless player?
                    # 观战者
                    log.mode="audience"
                        
                else if player.dead
                    # 天国
                    if player.type=="Spy" && player.flag=="spygone"
                        # 间谍なら会話に参加できない
                        log.mode="monologue"
                        log.to=player.id
                    else
                        log.mode="heaven"
                else if !game.night
                    # 昼
                    unless query.mode in player.getSpeakChoiceDay game
                        return
                    log.mode=query.mode
                    if game.silentexpires && game.silentexpires>=Date.now()
                        # まだ发言できない（15秒规则）
                        return
                    
                else
                    # 夜
                    unless query.mode in player.getSpeakChoice game
                        query.mode="monologue"
                    log.mode=query.mode

            switch log.mode
                when "monologue","helperwhisper"
                    # helperwhisper:守り先が決まっていない帮手
                    log.to=player.id
                when "gm"
                    log.name="GM→所有人"
                when "gmheaven"
                    log.name="GM→灵界"
                when "gmaudience"
                    log.name="GM→观战者"
                when "gmmonologue"
                    log.name="GM自言自语"
                when "prepare"
                    # ごちゃごちゃ言わない
                else
                    if result=query.mode?.match /^gmreply_(.+)$/
                        log.mode="gmreply"
                        pl=game.getPlayer result[1]
                        unless pl?
                            return
                        log.to=pl.id
                        log.name="GM→#{pl.name}"
                    else if result=query.mode?.match /^helperwhisper_(.+)$/
                        log.mode="helperwhisper"
                        log.to=result[1]

            splashlog roomid,game,log
            res null
        if player?
            log.name=player.name
            log.userid=player.id
            dosp()
        else
            # 房间情報から探す
            Server.game.rooms.oneRoomS roomid,(room)=>
                pl=room.players.filter((x)=>x.realid==req.session.userId)[0]
                if pl?
                    log.name=pl.name
                else
                    log.mode="audience"
                dosp()
    # 夜の仕事・投票
    job:(roomid,query)->
        game=games[roomid]
        unless game?
            res {error:"游戏不存在"}
            return
        unless req.session.userId
            res {error:"请登陆"}
            return
        player=game.getPlayerReal req.session.userId
        unless player?
            res {error:"没有加入游戏"}
            return
        unless player in game.participants
            res {error:"没有加入游戏"}
            return
        ###
        if player.dead && player.deadJobdone game
            res {error:"你已经死了"}
            return
        ###
        jt=player.getjob_target()
        sl=player.makeJobSelection game
        ###
        if !(to=game.players.filter((x)->x.id==query.target)[0]) && jt!=0
            res {error:"这个对象不存在"}
            return
        if to?.dead && (!(jt & Player.JOB_T_DEAD) || !game.night) && (jt & Player.JOB_T_ALIVE)
            res {error:"对象已经死亡"}
            return
        ###
        unless player.checkJobValidity game,query
            res {error:"对象选择无效"}
            return
        if game.night || query.jobtype!="_day"  # 昼の投票
            # 夜
            ###
            if !to?.dead && !(player.job_target & Player.JOB_T_ALIVE) && (player.job_target & Player.JOB_T_DEAD)
                res {error:"対象はまだ生きています"}
                return
            ###
            if (player.dead && player.deadJobdone(game)) || (!player.dead && player.jobdone(game))
                res {error:"已经使用了能力"}
                return
            unless player.isJobType query.jobtype
                res {error:"职业错误"}
                return
            # 错误メッセージ
            if ret=player.job game,query.target,query
                console.log "err!",ret
                res {error:ret}
                return
            # 能力発動を記録
            game.addGamelog {
                id:player.id
                type:query.jobtype
                target:query.target
                event:"job"
            }
            
            # 能力をすべて発動したかどうかチェック
            #res {sleeping:player.jobdone(game)}
            res makejobinfo game,player
            if game.night || game.day==0
                game.checkjobs()
        else
            # 投票
            ###
            if @votingbox.isVoteFinished player
                res {error:"既に投票しています"}
                return
            if query.target==player.id && game.rule.votemyself!="ok"
                res {error:"自己には投票できません"}
                return
            to=game.getPlayer query.target
            unless to?
                res {error:"その人には投票できません"}
                return
            ###
            unless player.checkJobValidity game,query
                res {error:"请选择对象"}
                return
            err=player.dovote game,query.target
            if err?
                res {error:err}
                return
            #player.dovote query.target
            # 投票が終わったかチェック
            game.addGamelog {
                id:player.id
                type:player.type
                target:query.target
                event:"vote"
            }
            res makejobinfo game,player
            game.execute()
    #遗言
    will:(roomid,will)->
        game=games[roomid]
        unless game?
            res "游戏不存在"
            return
        unless req.session.userId
            res "请登陆"
            return
        unless !game.rule || game.rule.will
            res "不能使用遗言"
            return
        player=game.getPlayerReal req.session.userId
        unless player?
            res "没有加入游戏"
            return
        if player.dead
            res "你已经死了"
            return
        player.setWill will
        res null
    #强行退出
    norevive:(roomid)->
        game=games[roomid]
        unless game?
            res "游戏不存在"
            return
        unless req.session.userId
            res "请登陆"
            return
        player=game.getPlayerReal req.session.userId
        unless player?
            res "没有加入游戏"
        # kill no revive player immediately
        player.die game,"gone-norevive"
        player.setNorevive true
        game.bury("other")
        ###
        log=
            mode:"userinfo"
            comment:"#{player.name} 强行退出了。"
            to:player.id
        splashlog roomid,game,log
        ###
        # 全员に通知
        game.splashjobinfo()
        res null

        

splashlog=(roomid,game,log)->
    log.time=Date.now() # 时间を付加
    game.logs.push log
    #DBに追加
    M.games.update {id:roomid},{$push:{logs:log}}
    flash=(log,rev=false)-> #rev: 逆な感じで配信
        # まず观战者
        log.roomid=roomid
        au=islogOK game,null,log
        if (au&&!rev) || (!au&&rev)
            game.ss.publish.channel "room#{roomid}_audience","log",log
        # GM
        #if game.gm&&!rev
        #   game.ss.publish.channel "room#{roomid}_gamemaster","log",log
        # 其他
        game.participants.forEach (pl)->
            p=islogOK game,pl,log
            if (p&&!rev) || (!p&&rev)
                game.ss.publish.user pl.realid,"log",log
    flash log
    
    # 他の人へ送る
    if log.mode=="werewolf" && game.rule.wolfsound=="aloud"
        # 狼的远吠が能听到
        otherslog=
            mode:"werewolf"
            comment:"嗷呜・・・"
            name:"狼的远吠"
            time:log.time
        flash otherslog,true
    else if log.mode=="couple" && game.rule.couplesound=="aloud"
        # 能听到共有者的低语声
        otherslog=
            mode:"couple"
            comment:"沙沙・・・"
            name:"共有者的低语声"
            time:log.time
        flash otherslog,true
    
    
            
    
    

# プレイヤーにログを見せてもよいか          
islogOK=(game,player,log)->
    # player: Player / null
    return true if game.finished    # 终了ならtrue
    return true if player?.isJobType "GameMaster"
    unless player?
        # 观战者
        if log.mode in ["day","system","prepare","nextturn","audience","will","gm","gmaudience","probability_table"]
            !log.to?    # 观战者にも公開
        else if log.mode=="voteresult"
            game.rule.voteresult!="hide"    # 投票结果公開なら公開
        else
            false   # 其他は非公開
    else if log.mode=="gmmonologue"
        # GM自言自语はGMにしか見えない
        false
    else if player.dead && game.heavenview
        true
    else if log.to? && log.to!=player.id
        # 個人宛
        if player.isJobType "Helper"
            log.to==player.flag # ヘルプ先のも見える
        else
            false
    else
        player.isListener game,log
#job情報を
makejobinfo = (game,player,result={})->
    result.type= if player? then player.getTypeDisp() else null
    # job情報表示するか
    actpl=player
    if player?
        if player instanceof Helper
            actpl=game.getPlayer player.flag
            unless actpl?
                #あれっ
                actpl=player
    openjob_flag=game.finished || (actpl?.dead && game.heavenview) || actpl?.isJobType("GameMaster")
    result.openjob_flag = openjob_flag

    result.game=game.publicinfo({openjob:openjob_flag})  # 终了か灵界（规则设定あり）の場合は職情報公開
    result.id=game.id

    if player
        # 参加者としての（perticipantsは除く）
        plpl=game.getPlayer player.id
        player.makejobinfo game,result
        result.dead=player.dead
        result.voteopen=false
        result.sleeping=true
        # 投票が终了したかどうか（表单表示するかどうか判断）
        if plpl?
            # 参加者として
            if game.night || game.day==0
                if player.dead
                    result.sleeping=player.deadJobdone game
                else
                    result.sleeping=player.jobdone game
            else
                # 昼
                result.sleeping=true
                unless player.dead || game.votingbox.isVoteFinished player
                    # 投票ボックスオープン!!!
                    result.voteopen=true
                    result.sleeping=false
                if player.chooseJobDay game
                    # 昼でも能力発動できる人
                    result.sleeping &&= player.jobdone game
        else
            # それ以外（participants）
            result.sleeping=if game.night then player.jobdone(game) else true
        result.jobname=player.getJobDisp()
        result.winner=player.winner
        if game.night || game.day==0
            result.speak =player.getSpeakChoice game
        else
            result.speak =player.getSpeakChoiceDay game
        if game.rule?.will=="die"
            result.will=player.will

    result
    
# 配列シャッフル（破壊的）
shuffle= (arr)->
    ret=[]
    while arr.length
        ret.push arr.splice(Math.floor(Math.random()*arr.length),1)[0]
    ret
    
# 游戏情報ツイート
tweet=(roomid,message)->
    Server.oauth.template roomid,message,Config.admin.password
        
