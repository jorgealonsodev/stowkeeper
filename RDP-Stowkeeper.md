# RDP — Project Stowkeeper

**Sistema de Backup Cifrado con Rotación y Notificaciones**

**Documento:** Registro de Decisiones de Proyecto (RDP)
**Versión:** 1.0
**Fecha:** 2 de mayo de 2026
**Estado:** Aprobado para implementación

---

## 1. Resumen ejecutivo

Diseño e implementación de un sistema de backup automatizado, cifrado de extremo a extremo, con rotación inteligente, verificación periódica de integridad y notificaciones multicanal (Telegram + email). El sistema cubre servidores Linux (físicos y virtuales) y workstations, con almacenamiento local (NAS) y replicación remota off-site.

El objetivo es disponer de una solución reproducible mediante código (IaC), de bajo coste operativo, resistente a ransomware (gracias a repositorios append-only) y con observabilidad suficiente para detectar fallos antes de que se conviertan en pérdida de datos.

---

## 2. Objetivos y alcance

### 2.1 Objetivos

El sistema persigue tres objetivos primarios. Primero, **garantizar la recuperabilidad** de los datos críticos cumpliendo la regla 3-2-1 (tres copias, dos soportes distintos, una off-site). Segundo, **minimizar la ventana de exposición** ante pérdida de datos manteniendo un RPO máximo de 24 horas para datos generales y 1 hora para bases de datos. Tercero, **detectar proactivamente** cualquier degradación silenciosa del repositorio mediante verificaciones automáticas de integridad.

### 2.2 RPO y RTO objetivo

| Categoría de dato | RPO | RTO |
|---|---|---|
| Bases de datos transaccionales | 1 hora | 2 horas |
| Sistemas de ficheros generales | 24 horas | 4 horas |
| Configuraciones (`/etc`) | 24 horas | 1 hora |
| Datos de usuario (workstations) | 24 horas | 8 horas |

### 2.3 Fuera de alcance

Quedan fuera del alcance de este proyecto los backups de aplicaciones SaaS de terceros (Microsoft 365, Google Workspace), que requieren herramientas específicas, así como la réplica síncrona de bases de datos en alta disponibilidad, que es un mecanismo complementario pero distinto al backup.

---

## 3. Decisiones de diseño

Esta sección documenta las decisiones técnicas tomadas, con su justificación y las alternativas descartadas.

### 3.1 Motor de backup: **Restic**

Se elige **Restic** frente a BorgBackup por las siguientes razones:

- **Soporte nativo de múltiples backends**: S3, B2, Azure Blob, SFTP, REST y filesystem local sin necesidad de herramientas adicionales como `rclone`. BorgBackup requiere SSH o un servidor Borg dedicado, lo que limita la flexibilidad para almacenamiento off-site en object storage.
- **Binario único en Go, sin dependencias**: simplifica el despliegue en clientes heterogéneos.
- **Repositorio multi-cliente**: varios hosts pueden escribir en el mismo repositorio Restic con deduplicación cruzada, algo que Borg solo soporta de forma limitada y con riesgo de corrupción si hay concurrencia.
- **Ecosistema activo y documentación madura**.

BorgBackup ofrece una compresión ligeramente superior y mejor rendimiento en redes de baja latencia, pero la flexibilidad de backends y la deduplicación multi-cliente de Restic pesan más en este proyecto.

### 3.2 Topología de repositorios: **dos repositorios independientes**

Se mantienen **dos repositorios completamente independientes**, no una réplica de uno a otro:

1. **Repositorio primario**: NAS local accesible por SFTP/NFS en la LAN.
2. **Repositorio secundario**: Backblaze B2 (object storage off-site).

Cada cliente ejecuta dos backups, uno contra cada repositorio. Esta decisión es deliberada: si se replicase el repositorio primario al secundario (por ejemplo con `rclone sync`), una corrupción o cifrado por ransomware del primario se propagaría al secundario. Con dos repositorios independientes, cada uno es una línea de defensa autónoma.

El coste adicional (doble subida de datos) se compensa con la deduplicación de Restic, que en backups incrementales reduce el tráfico real a un porcentaje pequeño de los cambios.

### 3.3 Almacenamiento off-site: **Backblaze B2**

Se elige **Backblaze B2** como destino off-site por su precio (≈6 USD/TB/mes en almacenamiento, sin coste de egreso hasta 3× lo almacenado al mes), su API compatible con S3 y su fiabilidad demostrada. AWS S3 y Azure Blob ofrecen funcionalidad similar pero a un coste 3-4 veces superior para este caso de uso. Wasabi sería una alternativa válida pero su política de retención mínima de 90 días penaliza la rotación frecuente.

### 3.4 Cifrado: **AES-256 nativo de Restic con passphrase derivada**

El cifrado se delega íntegramente al motor de Restic, que aplica AES-256 en modo CTR con autenticación Poly1305 y deriva la clave de una passphrase mediante scrypt. **El cifrado ocurre en el cliente antes de cualquier transmisión**, lo que significa que el operador del NAS o de Backblaze nunca tiene acceso al contenido en claro.

#### Gestión de passphrases

- Cada repositorio tiene su propia passphrase de **al menos 40 caracteres aleatorios** generada con `openssl rand -base64 30`.
- Las passphrases se almacenan en **HashiCorp Vault** (instancia self-hosted) y se inyectan en los clientes mediante AppRole con TTL corto.
- Existe una **copia impresa en papel** de cada passphrase guardada en caja fuerte física, como último recurso ante pérdida total de Vault.
- Restic permite múltiples claves por repositorio: se mantiene una clave operativa por host y una clave de emergencia ("master") guardada solo en papel.

### 3.5 Política de retención y rotación

Se aplica una política **GFS (Grandfather-Father-Son)** ligeramente adaptada, gestionada por `restic forget` con las siguientes flags:

```
--keep-last 3
--keep-hourly 24
--keep-daily 14
--keep-weekly 8
--keep-monthly 12
--keep-yearly 5
```

Esto produce, en régimen estable, alrededor de 60-65 snapshots retenidos por host, lo que con la deduplicación de Restic supone típicamente entre 1.3× y 1.8× el tamaño de los datos en producción. La retención anual de 5 años cubre requisitos típicos de auditoría; si el contexto regulatorio (sanitario, financiero) exige más, se ajustará por host.

El comando `restic forget` se ejecuta con `--prune` solo una vez por semana (operación costosa), y los demás días solo marca snapshots sin liberar espacio.

### 3.6 Frecuencia de ejecución

| Tipo de dato | Frecuencia | Mecanismo |
|---|---|---|
| Bases de datos (PostgreSQL, MySQL) | Cada hora | systemd timer + dump pre-backup |
| `/etc` y configuraciones | Diaria a las 02:00 | systemd timer |
| Volúmenes de datos generales | Diaria a las 03:00 | systemd timer |
| Workstations | Al conectar a red corporativa, máx. 1×/día | systemd path unit |
| Verificación `restic check` | Semanal (domingo 04:00) | systemd timer |
| Verificación profunda (`--read-data`) | Mensual | systemd timer |

Se eligen **systemd timers** sobre cron porque ofrecen mejor logging (journald), gestión de dependencias, ejecución diferida si el sistema estuvo apagado (`Persistent=true`) y aleatorización para evitar tormentas de I/O (`RandomizedDelaySec`).

### 3.7 Backup consistente de bases de datos

Las bases de datos no se respaldan copiando ficheros del datadir directamente. En su lugar:

- **PostgreSQL**: `pg_dump` con formato custom (`-Fc`) por base de datos, más `pg_basebackup` semanal para una copia binaria completa con WAL.
- **MySQL/MariaDB**: `mariabackup` (snapshot consistente sin bloquear) o `mysqldump --single-transaction` para bases pequeñas.
- **SQLite**: `sqlite3 .backup` para garantizar consistencia.

Los dumps se escriben a un directorio temporal, Restic los respalda, y se borran después. Para volúmenes grandes (>100 GB), se considera el uso de **stdin a Restic** (`pg_dump | restic backup --stdin`) para evitar el doble almacenamiento.

### 3.8 Verificación de integridad

La verificación opera en tres niveles:

1. **Diaria**: el propio `restic backup` valida los chunks subidos.
2. **Semanal**: `restic check` (sin `--read-data`) verifica la estructura del repositorio y la consistencia de los índices. Es rápida.
3. **Mensual**: `restic check --read-data-subset=10%` lee y verifica el 10% de los datos rotando el subconjunto cada mes, lo que cubre el 100% del repositorio en 10 meses sin sobrecargar la red.

Una vez al trimestre se ejecuta una **prueba de restauración real** automatizada: se restaura un snapshot a un directorio temporal, se compara un subconjunto de ficheros con `sha256sum` contra los originales, y se notifica el resultado. Un backup nunca verificado mediante restauración no es un backup.

### 3.9 Notificaciones: **Telegram + email vía script wrapper**

Las notificaciones se gestionan con un **script wrapper en Bash** (`backup-runner.sh`) que envuelve cada ejecución de Restic, captura código de salida, duración, tamaño y stderr, y emite la notificación por los canales configurados.

#### Canales

- **Telegram (canal primario)**: usando un bot dedicado y un grupo privado de operaciones. Permite emojis, formato Markdown y respuesta rápida desde móvil.
- **Email (canal secundario, fallback y archivo)**: vía `msmtp` con relay autenticado a un SMTP corporativo o a un servicio como Postmark/Amazon SES.

#### Política de notificaciones

Para evitar **fatiga de alertas**:

- **Éxitos**: solo se notifica un resumen diario consolidado a las 08:00 (no cada job).
- **Fallos**: notificación inmediata por Telegram **y** email.
- **Avisos** (warnings, p. ej. backup que tardó >2× su mediana): notificación por Telegram solamente.
- **Verificaciones fallidas**: alerta de máxima prioridad, con ping a operador on-call.

El script implementa **deduplicación de alertas** (no enviar la misma alerta más de una vez cada 4 horas) y **circuit breaker** (si fallan 5 jobs seguidos, escalar a llamada telefónica vía PagerDuty/OpsGenie).

### 3.10 Hardening contra ransomware

- **Append-only en Backblaze B2**: el cliente usa una Application Key con permisos `write` pero no `delete`. La rotación con `restic forget --prune` se ejecuta desde un host de gestión separado con credenciales distintas, que solo se activan durante la ventana de mantenimiento semanal.
- **Object Lock** en B2 con retención de 30 días sobre el bucket: incluso credenciales comprometidas no pueden borrar objetos durante ese periodo.
- **Repositorio NAS en sistema de ficheros con snapshots ZFS**: el NAS toma un snapshot ZFS read-only diario del repositorio Restic, retenido 30 días. Esto crea una capa adicional de protección incluso si las credenciales del cliente fuesen comprometidas.

### 3.11 Despliegue y configuración

La configuración del sistema se gestiona mediante **Ansible**:

- Un rol `backup_client` que instala Restic, despliega el wrapper, configura systemd timers, integra con Vault y registra el host.
- Variables por host en `host_vars/` con la lista de paths a respaldar y excepciones.
- El binario de Restic se distribuye desde un mirror interno con su checksum verificado, no se descarga de internet en cada ejecución.

---

## 4. Arquitectura

### 4.1 Diagrama lógico

```
                      ┌──────────────────────┐
                      │   Vault (secrets)    │
                      └──────────┬───────────┘
                                 │ AppRole
                                 │
   ┌──────────┐  ┌──────────┐    │   ┌──────────┐
   │ Server A │  │ Server B │    │   │  WS X    │
   │ (Restic) │  │ (Restic) │ ◄──┘   │ (Restic) │
   └────┬─────┘  └────┬─────┘        └────┬─────┘
        │             │                    │
        │ SFTP        │                    │ HTTPS
        ▼             ▼                    ▼
    ┌────────────────────┐         ┌──────────────────┐
    │   NAS (ZFS)        │         │  Backblaze B2    │
    │   Repo primario    │         │  Repo secundario │
    │   + ZFS snapshots  │         │  + Object Lock   │
    └────────────────────┘         └──────────────────┘

        ┌───────────────────────────────────────────┐
        │ backup-runner.sh → Telegram + email        │
        └───────────────────────────────────────────┘
```

### 4.2 Componentes

El **wrapper `backup-runner.sh`** es el único punto de entrada para cualquier ejecución de Restic. Centraliza autenticación con Vault, manejo de bloqueos (lockfile en `/var/lock/backup-runner.lock` para evitar solapamientos), captura de métricas, lógica de notificación y registro en journald con tags estructurados para facilitar consultas posteriores.

El **host de mantenimiento** es una máquina dedicada (puede ser una VM pequeña) que ejecuta semanalmente las operaciones destructivas (`forget --prune`) y la verificación de integridad. Está aislado de los clientes y solo tiene credenciales con permisos elevados durante la ventana de mantenimiento.

---

## 5. Operaciones

### 5.1 Procedimiento de restauración

Documentado en runbook separado, pero a alto nivel:

1. Identificar el snapshot deseado: `restic snapshots --host <hostname>`.
2. Restaurar a directorio temporal: `restic restore <id> --target /tmp/restore`.
3. Validar contenido antes de sobrescribir originales.
4. Mover/copiar a destino final.

Se mantienen runbooks específicos para escenarios concretos (recuperación de base de datos, recuperación bare-metal, recuperación selectiva de ficheros).

### 5.2 Pruebas trimestrales

Cada trimestre, el equipo de operaciones realiza un ejercicio de DR donde:

- Se restaura un servidor completo a un entorno aislado a partir solo de los backups.
- Se mide el RTO real obtenido y se compara con el objetivo.
- Se documentan incidencias y se actualiza la documentación.

### 5.3 Métricas y observabilidad

El wrapper exporta métricas a un endpoint Prometheus (`textfile collector` de node_exporter):

- `backup_last_success_timestamp{host, repo}`
- `backup_duration_seconds{host, repo}`
- `backup_size_bytes{host, repo}`
- `backup_files_new{host, repo}`
- `backup_check_last_success_timestamp{repo}`

Sobre estas métricas se construyen alertas en Alertmanager: backup más viejo de 30 horas, verificación más vieja de 10 días, crecimiento anormal del repositorio (>50% en una semana).

---

## 6. Coste estimado

Para un volumen de referencia de **2 TB de datos en producción** con factor de deduplicación típico de 1.5×:

| Concepto | Coste mensual |
|---|---|
| Backblaze B2 (3 TB almacenado) | ≈18 USD |
| B2 egreso (suponiendo 1 restauración trimestral parcial) | ≈3 USD promedio |
| NAS (amortización + electricidad) | ≈25 USD |
| Postmark/SES (email) | <1 USD |
| Telegram | 0 USD |
| **Total mensual estimado** | **≈47 USD** |

El coste de personal (operación, monitorización, pruebas trimestrales) es el componente dominante real y se estima en 4-6 horas/mes en régimen estable.

---

## 7. Riesgos y mitigaciones

| Riesgo | Impacto | Probabilidad | Mitigación |
|---|---|---|---|
| Pérdida de passphrase | Crítico | Baja | Vault + copia en papel en caja fuerte |
| Compromiso de cliente con escritura en repo | Alto | Media | Append-only key + Object Lock + ZFS snapshots |
| Corrupción silenciosa del repo | Alto | Baja | `restic check --read-data` mensual rotativo |
| Fallo del NAS | Medio | Media | Repositorio B2 independiente cubre el caso |
| Backup nunca probado | Crítico | — | Restauraciones automáticas trimestrales |
| Crecimiento descontrolado de coste B2 | Bajo | Media | Alertas Prometheus sobre tamaño de repo |

---

## 8. Plan de implementación

La implementación se estructura en cuatro fases incrementales. La **fase 1** (semanas 1-2) consiste en el despliegue del repositorio primario en NAS, la configuración del wrapper y los timers en un host piloto, y la validación del flujo completo de notificaciones. La **fase 2** (semanas 3-4) añade el repositorio secundario en B2, la integración con Vault y el endurecimiento append-only. La **fase 3** (semanas 5-6) extiende el rol Ansible al resto de servidores y workstations. La **fase 4** (semana 7-8) implementa las verificaciones automáticas, las pruebas de restauración y las alertas Prometheus, cerrando el ciclo de observabilidad.

Cada fase termina con un punto de control explícito: la fase no se da por cerrada hasta que las pruebas correspondientes pasan en el entorno real.

---

## 9. Decisiones pendientes

Quedan abiertas para revisión en una próxima iteración: (a) la inclusión de una tercera copia en almacenamiento físico desconectado (cinta LTO o disco rotativo) para datos sometidos a retención legal de más de 5 años; (b) la migración eventual del wrapper Bash a un binario Go más robusto si la complejidad crece; (c) la evaluación de `resticprofile` como capa de configuración declarativa sobre Restic.

---

## 10. Referencias

- Documentación oficial de Restic: <https://restic.readthedocs.io>
- Backblaze B2 Object Lock: <https://www.backblaze.com/b2/docs/file_lock.html>
- HashiCorp Vault AppRole: <https://developer.hashicorp.com/vault/docs/auth/approle>
- Regla 3-2-1 de backup: práctica estándar de la industria, originalmente formulada por Peter Krogh.

---

*Fin del documento.*
