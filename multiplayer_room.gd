extends Node
## Autoload MultiplayerRoom: gerencia salas de coop por codigo. O MESMO
## script roda tanto no servidor dedicado (scripts/dedicated_server.gd)
## quanto no jogo normal do jogador — como e um autoload identico dos dois
## lados, os RPCs alcancam o mesmo caminho de no nas duas pontas.
##
## Funcoes "server_*"/"create_room"/"join_room"/"start_match" so fazem
## algo quando chamadas NO SERVIDOR (guardadas por multiplayer.is_server());
## as callbacks "_on_*" so fazem algo quando recebidas NO CLIENTE.

signal connected_to_server
signal connection_failed
signal disconnected_from_server
signal room_updated(code, players, host_peer_id)
signal join_failed(message)
signal match_started(players)
signal coop_wave_advanced(wave_number, enemy_ids)
signal coop_enemy_hp_changed(wave_number, enemy_index, hp, max_hp)
signal coop_enemy_died(wave_number, enemy_index, exp_value, gold_value, killer_peer_id)
signal coop_match_ended(scores, final_wave)
signal coop_damage_totals_changed(damage_by_peer)
signal friends_presence_result(online_usernames)
signal trade_proposed(from_username, item_uid, item_id, rarity, enhance_level, bonus_effects, price_gold)
signal trade_response(item_uid, accepted, price_gold)
signal trade_failed(message)

const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const MAX_PLAYERS_PER_ROOM := 4
const SERVER_HOST := "champions-multiversos.duckdns.org"
const SERVER_PORT := 9050
const COOP_MATCH_SCRIPT := preload("res://scripts/coop_match.gd")

## --- Estado do servidor (so populado/usado quando multiplayer.is_server()) ---
var rooms: Dictionary = {}       # code(String) -> { "host": peer_id, "players": {peer_id: {...}}, "started": bool }
var peer_room: Dictionary = {}   # peer_id(int) -> code(String)
## Presenca online (Fase C.7): todo peer conectado ao servidor (nao so quem
## esta numa sala) se identifica com username via register_identity(), pra
## qualquer outro jogador poder perguntar "esse amigo esta online agora?"
## sem precisar estar na mesma sala/partida.
var peer_username: Dictionary = {}     # peer_id(int) -> username(String)
var online_usernames: Dictionary = {}  # username(String) -> peer_id(int)

## --- Estado do cliente ---
var my_room_code := ""
var my_players: Dictionary = {}
var my_host_peer_id := -1

func is_local_host() -> bool:
	return my_host_peer_id != -1 and multiplayer.get_unique_id() == my_host_peer_id

## Verdadeiro assim que ha uma conexao ativa com o servidor dedicado —
## usado pra HubScreen/LobbyScreen nao tentarem abrir uma segunda conexao
## por cima de uma que ja existe (o mesmo peer serve pra presenca E salas).
func is_connected_to_server() -> bool:
	return multiplayer.multiplayer_peer != null

func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func connect_to_server(ip: String, port: int) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(_on_connection_failed, CONNECT_ONE_SHOT)
	multiplayer.server_disconnected.connect(_on_server_disconnected, CONNECT_ONE_SHOT)

func _on_connected_to_server() -> void:
	connected_to_server.emit()

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed.emit()

func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	my_room_code = ""
	my_players = {}
	disconnected_from_server.emit()

func disconnect_from_server() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	my_room_code = ""
	my_players = {}

## ---- Presenca online (Fase C.7) ----

## Chamado pelo cliente assim que conecta (tipicamente ao abrir o Hub) pra
## o servidor saber "esse peer e esse jogador logado", habilitando
## check_friends_online() de qualquer outro cliente.
@rpc("any_peer", "call_remote", "reliable")
func register_identity(username: String) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	peer_username[peer_id] = username
	online_usernames[username] = peer_id

## Chamado pelo cliente (tipicamente na tela de Amigos) com a lista de
## usernames dos amigos, pra saber quais deles estao conectados agora.
@rpc("any_peer", "call_remote", "reliable")
func check_friends_online(usernames: Array) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var online: Array = []
	for u in usernames:
		if online_usernames.has(u):
			online.append(u)
	rpc_id(peer_id, "_on_friends_presence", online)

@rpc("authority", "call_remote", "reliable")
func _on_friends_presence(online_usernames_result: Array) -> void:
	friends_presence_result.emit(online_usernames_result)

## ---- Negociacao em tempo real (Fase C.8) ----
## O servidor so retransmite a proposta/resposta entre os dois peers
## conectados (nao mexe em banco de dados nenhum) — cada cliente aplica o
## resultado na propria conta de forma independente (ver
## game_data.gd:remove_item_from_inventory/add_full_item_instance).

## Chamado pelo cliente que esta oferecendo o item. `item_uid` so faz
## sentido na conta de quem propoe (usado na resposta pra ele saber qual
## item remover); rarity/enhance_level/bonus_effects viajam junto pra quem
## recebe poder recriar uma copia fiel na propria conta. `price_gold` (0 =
## presente) e o preco em gold que o ALVO paga pro proponente ao aceitar —
## vira o "mercado de um pra um": mesmo modelo de confianca ja usado pro
## item (cada lado muta a propria conta e sincroniza sozinho, sem banco de
## dados central no meio), agora estendido a gold.
@rpc("any_peer", "call_remote", "reliable")
func propose_trade(target_username: String, item_uid: String, item_id: String, rarity: String, enhance_level: int, bonus_effects: Array, price_gold: int) -> void:
	if not multiplayer.is_server():
		return
	var from_peer := multiplayer.get_remote_sender_id()
	if not online_usernames.has(target_username):
		rpc_id(from_peer, "_on_trade_failed", "Jogador offline.")
		return
	var target_peer: int = online_usernames[target_username]
	var from_username: String = peer_username.get(from_peer, "?")
	rpc_id(target_peer, "_on_trade_proposed", from_username, item_uid, item_id, rarity, enhance_level, bonus_effects, price_gold)

## Chamado pelo cliente que recebeu a proposta, aceitando ou recusando.
## `target_username` aqui e quem PROPOS a troca (o destino da resposta).
@rpc("any_peer", "call_remote", "reliable")
func respond_trade(target_username: String, item_uid: String, accepted: bool, price_gold: int) -> void:
	if not multiplayer.is_server():
		return
	var from_peer := multiplayer.get_remote_sender_id()
	if not online_usernames.has(target_username):
		return
	var target_peer: int = online_usernames[target_username]
	rpc_id(target_peer, "_on_trade_response", item_uid, accepted, price_gold)

@rpc("authority", "call_remote", "reliable")
func _on_trade_proposed(from_username: String, item_uid: String, item_id: String, rarity: String, enhance_level: int, bonus_effects: Array, price_gold: int) -> void:
	trade_proposed.emit(from_username, item_uid, item_id, rarity, enhance_level, bonus_effects, price_gold)

@rpc("authority", "call_remote", "reliable")
func _on_trade_response(item_uid: String, accepted: bool, price_gold: int) -> void:
	trade_response.emit(item_uid, accepted, price_gold)

@rpc("authority", "call_remote", "reliable")
func _on_trade_failed(message: String) -> void:
	trade_failed.emit(message)

## ---- Chamado pelo cliente pra pedir uma acao ao servidor ----

@rpc("any_peer", "call_remote", "reliable")
func create_room(player_name: String, race_id: String, weapon_id: String) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	_server_leave_current_room(peer_id)
	var code := _generate_unique_code()
	rooms[code] = {
		"host": peer_id,
		"players": {peer_id: {"name": player_name, "race_id": race_id, "weapon_id": weapon_id, "ready": false}},
		"started": false,
	}
	peer_room[peer_id] = code
	rpc_id(peer_id, "_on_room_joined", code, rooms[code]["players"], peer_id)

@rpc("any_peer", "call_remote", "reliable")
func join_room(code: String, player_name: String, race_id: String, weapon_id: String) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var normalized := code.strip_edges().to_upper()
	if not rooms.has(normalized):
		rpc_id(peer_id, "_on_join_failed", "Sala nao encontrada.")
		return
	var room: Dictionary = rooms[normalized]
	if room["started"]:
		rpc_id(peer_id, "_on_join_failed", "Essa partida ja comecou.")
		return
	if room["players"].size() >= MAX_PLAYERS_PER_ROOM:
		rpc_id(peer_id, "_on_join_failed", "Sala cheia.")
		return
	_server_leave_current_room(peer_id)
	room["players"][peer_id] = {"name": player_name, "race_id": race_id, "weapon_id": weapon_id, "ready": false}
	## Um jogador novo entrando muda quem precisa concordar — reseta o
	## "pronto" de todo mundo, pra a sala nunca comecar sem esse jogador
	## ter clicado em pronto tambem.
	for pid2 in room["players"].keys():
		room["players"][pid2]["ready"] = false
	peer_room[peer_id] = normalized
	_broadcast_room(normalized)

@rpc("any_peer", "call_remote", "reliable")
func leave_room() -> void:
	if not multiplayer.is_server():
		return
	_server_leave_current_room(multiplayer.get_remote_sender_id())

## Chamado pelo cliente (LobbyScreen) ao sair de uma sala. So avisa o
## servidor e limpa o estado local da sala — NAO derruba a conexao, pra nao
## quebrar a presenca online compartilhada com o Hub (ver
## hub_screen.gd:_ensure_presence_connection). Full disconnect_from_server()
## continua existindo pra quando o jogador realmente quer encerrar a conexao
## (ex. sair do app).
func leave_current_room() -> void:
	if is_connected_to_server():
		leave_room.rpc_id(1)
	my_room_code = ""
	my_players = {}
	my_host_peer_id = -1

## Chamado pelo cliente ao marcar/desmarcar "pronto" na sala. A partida so
## comeca automaticamente quando TODOS os jogadores presentes estiverem
## prontos ao mesmo tempo — sem botao de "iniciar" separado do anfitriao,
## igual o fluxo padrao de sala pronta em jogos online.
@rpc("any_peer", "call_remote", "reliable")
func set_ready(is_ready: bool) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not peer_room.has(peer_id):
		return
	var code: String = peer_room[peer_id]
	var room: Dictionary = rooms[code]
	if room["started"] or not room["players"].has(peer_id):
		return
	room["players"][peer_id]["ready"] = is_ready
	_broadcast_room(code)
	if is_ready and _all_players_ready(room):
		_begin_match(code)

func _all_players_ready(room: Dictionary) -> bool:
	for p in room["players"].values():
		if not p.get("ready", false):
			return false
	return true

func _begin_match(code: String) -> void:
	var room: Dictionary = rooms[code]
	room["started"] = true

	var match_ctrl := Node.new()
	match_ctrl.set_script(COOP_MATCH_SCRIPT)
	add_child(match_ctrl)
	match_ctrl.wave_advanced.connect(func(wave_number, enemy_ids): _on_match_wave_advanced(code, wave_number, enemy_ids))
	match_ctrl.enemy_hp_changed.connect(func(wave_number, idx, hp, max_hp): _on_match_enemy_hp_changed(code, wave_number, idx, hp, max_hp))
	match_ctrl.enemy_died.connect(func(wave_number, idx, exp_v, gold_v, killer): _on_match_enemy_died(code, wave_number, idx, exp_v, gold_v, killer))
	match_ctrl.damage_totals_changed.connect(func(totals): _on_match_damage_totals(code, totals))
	room["match"] = match_ctrl

	var players_keys: Array = room["players"].keys()
	match_ctrl.start(code, players_keys)
	for pid in players_keys:
		rpc_id(int(pid), "_on_match_started", room["players"])

## Chamado por um cliente ao acertar localmente um inimigo — o SERVIDOR
## decide se o dano realmente se aplica (o inimigo pode ja ter morrido
## pro golpe de outro jogador) e avisa a sala inteira do resultado real.
@rpc("any_peer", "call_remote", "unreliable")
func report_hit(enemy_index: int, damage: float) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not peer_room.has(peer_id):
		return
	var code: String = peer_room[peer_id]
	var room: Dictionary = rooms.get(code, {})
	var match_ctrl = room.get("match")
	if match_ctrl == null:
		return
	match_ctrl.apply_hit(enemy_index, damage, peer_id)

## Chamado por um cliente quando seu personagem morre. Quando todo mundo
## da sala reportou morte, a partida acaba e a pontuacao final (dano
## acumulado por jogador) e enviada pra todos.
@rpc("any_peer", "call_remote", "reliable")
func report_player_died() -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not peer_room.has(peer_id):
		return
	var code: String = peer_room[peer_id]
	var room: Dictionary = rooms.get(code, {})
	var match_ctrl = room.get("match")
	if match_ctrl == null:
		return
	match_ctrl.dead_peers[peer_id] = true
	if match_ctrl.dead_peers.size() >= match_ctrl.peer_ids.size():
		_end_match(code)

func _end_match(code: String) -> void:
	var room: Dictionary = rooms.get(code, {})
	var match_ctrl = room.get("match")
	if match_ctrl == null:
		return
	var scores: Dictionary = match_ctrl.damage_by_peer.duplicate()
	var final_wave: int = match_ctrl.wave
	for pid in room["players"].keys():
		rpc_id(int(pid), "_client_match_ended", scores, final_wave)
	match_ctrl.free()
	room.erase("match")
	room["started"] = false

func _on_match_wave_advanced(code: String, wave_number: int, enemy_ids: Array) -> void:
	if not rooms.has(code):
		return
	for pid in rooms[code]["players"].keys():
		rpc_id(int(pid), "_client_wave_advanced", wave_number, enemy_ids)

func _on_match_enemy_hp_changed(code: String, wave_number: int, idx: int, hp: float, max_hp: float) -> void:
	if not rooms.has(code):
		return
	for pid in rooms[code]["players"].keys():
		rpc_id(int(pid), "_client_enemy_hp_changed", wave_number, idx, hp, max_hp)

func _on_match_enemy_died(code: String, wave_number: int, idx: int, exp_v: int, gold_v: int, killer_peer: int) -> void:
	if not rooms.has(code):
		return
	for pid in rooms[code]["players"].keys():
		rpc_id(int(pid), "_client_enemy_died", wave_number, idx, exp_v, gold_v, killer_peer)

## Broadcast "informal" (unreliable) do dano acumulado por jogador — so pra
## alimentar a barra de dano da HUD em tempo real, nao afeta nenhuma logica
## de jogo (a pontuacao final oficial vem de _end_match/_client_match_ended).
func _on_match_damage_totals(code: String, totals: Dictionary) -> void:
	if not rooms.has(code):
		return
	for pid in rooms[code]["players"].keys():
		rpc_id(int(pid), "_client_damage_totals", totals)

func _server_leave_current_room(peer_id: int) -> void:
	if not peer_room.has(peer_id):
		return
	var code: String = peer_room[peer_id]
	peer_room.erase(peer_id)
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	room["players"].erase(peer_id)
	if room["players"].is_empty():
		var match_ctrl = room.get("match")
		if match_ctrl != null:
			match_ctrl.free()
		rooms.erase(code)
		return
	if room["host"] == peer_id:
		room["host"] = room["players"].keys()[0]
	_broadcast_room(code)
	## Se quem saiu era o unico que faltava ficar pronto, a sala pode comecar
	## agora — sem isso, os que ja estavam prontos ficariam presos ate
	## desmarcar/remarcar "pronto" de novo pra reacionar a checagem.
	if not room["started"] and _all_players_ready(room):
		_begin_match(code)

func _broadcast_room(code: String) -> void:
	var room: Dictionary = rooms[code]
	for pid in room["players"].keys():
		rpc_id(int(pid), "_on_room_joined", code, room["players"], room["host"])

func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	_server_leave_current_room(id)
	if peer_username.has(id):
		online_usernames.erase(peer_username[id])
		peer_username.erase(id)

func _generate_unique_code() -> String:
	var code := ""
	for i in range(5):
		code += CODE_CHARS[randi() % CODE_CHARS.length()]
	if rooms.has(code):
		return _generate_unique_code()
	return code

## ---- Recebido pelo cliente (chamado pelo servidor via rpc_id) ----

@rpc("authority", "call_remote", "reliable")
func _on_room_joined(code: String, players: Dictionary, host_peer_id: int) -> void:
	my_room_code = code
	my_players = players
	my_host_peer_id = host_peer_id
	room_updated.emit(code, players, host_peer_id)

@rpc("authority", "call_remote", "reliable")
func _on_join_failed(message: String) -> void:
	join_failed.emit(message)

@rpc("authority", "call_remote", "reliable")
func _on_match_started(players: Dictionary) -> void:
	my_players = players
	match_started.emit(players)

@rpc("authority", "call_remote", "reliable")
func _client_wave_advanced(wave_number: int, enemy_ids: Array) -> void:
	coop_wave_advanced.emit(wave_number, enemy_ids)

@rpc("authority", "call_remote", "unreliable_ordered")
func _client_enemy_hp_changed(wave_number: int, enemy_index: int, hp: float, max_hp: float) -> void:
	coop_enemy_hp_changed.emit(wave_number, enemy_index, hp, max_hp)

@rpc("authority", "call_remote", "reliable")
func _client_enemy_died(wave_number: int, enemy_index: int, exp_value: int, gold_value: int, killer_peer_id: int) -> void:
	coop_enemy_died.emit(wave_number, enemy_index, exp_value, gold_value, killer_peer_id)

@rpc("authority", "call_remote", "reliable")
func _client_match_ended(scores: Dictionary, final_wave: int) -> void:
	coop_match_ended.emit(scores, final_wave)

@rpc("authority", "call_remote", "unreliable")
func _client_damage_totals(damage_by_peer: Dictionary) -> void:
	coop_damage_totals_changed.emit(damage_by_peer)
