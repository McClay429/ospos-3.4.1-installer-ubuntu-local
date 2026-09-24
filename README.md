# Instalador no oficial de OSPOS 3.4.1 para Ubuntu (Apache + PHP 8.1 + MariaDB)

> ⚠️ **Este instalador está pensado para uso LOCAL, no para servidores
> expuestos a internet.**
>
> El script configura Apache en HTTP simple (u opcionalmente HTTPS con
> certificado **autofirmado**, solo válido para pruebas), sin firewall,
> sin hardening adicional, y asumiendo que accedes desde la misma red
> local (tu propia computadora, o una red doméstica/de negocio privada).
>
> **No lo uses tal cual en:**
> - Un VPS o servidor con IP pública accesible desde internet
> - Un contenedor Docker (este instalador es para LAMP tradicional —
>   OSPOS ya tiene su propia imagen oficial de Docker para ese caso)
> - Cualquier entorno donde alguien no autorizado pueda llegar a la IP
>
> Si en el futuro necesitas acceso remoto (por ejemplo, para administrar
> tu inventario desde fuera de casa/negocio), la recomendación es usar una
> VPN de malla como [Tailscale](https://tailscale.com/) o [WireGuard](https://www.wireguard.com/)
> **en vez de** exponer el puerto 80/443 directamente a internet. Esto no
> está automatizado en este script todavía — puede agregarse en una
> versión futura.

Este repositorio automatiza la instalación de [OSPOS (opensourcepos)](https://github.com/opensourcepos/opensourcepos)
versión **3.4.1** en un servidor Ubuntu 22.04/24.04 LTS con Apache 2.4, PHP 8.1
y MariaDB, corrigiendo **cinco bugs del paquete de distribución oficial**
que impiden que la aplicación funcione siguiendo únicamente la guía de
instalación estándar.

> ⚠️ Este no es un fork ni una versión modificada de OSPOS. Es un script que
> descarga el paquete oficial directamente desde el repositorio de
> `opensourcepos/opensourcepos` y le aplica correcciones **después** de
> descargarlo. El código de OSPOS en sí no se modifica ni se redistribuye
> aquí — solo se automatiza su instalación correcta.

## ¿Por qué existe esto?

El paquete de distribución (`opensourcepos.3.4.1.5f395d.zip`, el "prebuilt"
que aparece en la página de releases) tiene varios problemas que provocan
errores en cascada durante una instalación nueva sobre LAMP tradicional
(sin Docker). Cada uno está documentado a fondo en
[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md), pero en resumen:

1. Falta el archivo `app/Config/Locale.php` → error fatal en cualquier
   comando de consola (`spark migrate`, etc.) y en ciertas peticiones web.
2. Falta el archivo `spark` (la herramienta CLI de CodeIgniter 4).
3. `app/Config/Database.php` ignora las credenciales del `.env` y sólo lee
   variables de entorno `MYSQL_*` (diseño pensado para Docker), causando
   "Access denied" incluso con el `.env` bien configurado.
4. Falta la extensión PHP `bcmath`, causando un error fatal al calcular
   totales/impuestos.
5. El esquema `database.sql` incluido está desactualizado (no tiene las
   tablas ni columnas agregadas por migraciones posteriores a 3.1.1), así
   que hay que dejar correr las migraciones reales para completarlo.

Ninguno de estos problemas es intencional ni "normal" — son omisiones del
empaquetado de esa release específica. Este instalador simplemente hace,
de forma automática, todo lo que se necesita para llegar a una instalación
funcional.

## Requisitos previos

Este script **no instala** el stack base — asume que ya tienes:

- Ubuntu 22.04 o 24.04 LTS
- Apache 2.4 funcionando
- PHP 8.1 funcionando con Apache (`libapache2-mod-php` o equivalente)
- MariaDB (o MySQL) funcionando
- Una base de datos y un usuario **ya creados** en MariaDB, con permisos
  completos sobre esa base

Si no tienes esto listo, instálalo primero:

```bash
sudo apt update
sudo apt install apache2 php8.1 libapache2-mod-php8.1 mariadb-server -y
sudo mysql -u root -e "
CREATE DATABASE ospos CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'ospos'@'localhost' IDENTIFIED BY 'TU_CONTRASEÑA_AQUI';
GRANT ALL PRIVILEGES ON ospos.* TO 'ospos'@'localhost';
FLUSH PRIVILEGES;
"
```

> ⚠️ **No olvides reemplazar `TU_CONTRASEÑA_AQUI` por una contraseña real**
> antes de copiar y pegar el comando de arriba. Es un error fácil de
> cometer — si lo dejas tal cual, el
> usuario `ospos` de MariaDB queda literalmente con la contraseña
> `TU_CONTRASEÑA_AQUI`, y el script fallará más adelante al no coincidir
> con lo que le indiques en `DB_PASSWORD`.

## Uso

```bash
git clone <url-de-este-repo>
cd <este-repo>
chmod +x install-ospos.sh

# Opción A: edita las variables directamente al inicio del script
nano install-ospos.sh

# Opción B: pásalas como variables de entorno
export DB_NAME="ospos"
export DB_USER="ospos"
export DB_PASSWORD="tu_contraseña"
export APP_BASE_URL="http://localhost/"

sudo -E ./install-ospos.sh
```

El script te pedirá la contraseña de la base de datos de forma interactiva
si no la defines por variable de entorno.

### Opciones del script

```bash
sudo ./install-ospos.sh              # Instala normalmente
sudo ./install-ospos.sh --dry-run    # Muestra qué haría, sin ejecutar nada
sudo ./install-ospos.sh --uninstall  # Elimina la instalación (no borra la BD)
sudo ./install-ospos.sh --https      # Además configura HTTPS con certificado autofirmado
./install-ospos.sh --help            # Muestra la ayuda
```

### Validaciones previas (fail-fast)

Antes de descargar o instalar nada, el script verifica:
- Que se esté corriendo con `sudo`/root
- Que PHP, Apache y MariaDB/MySQL estén instalados **y corriendo**
- Que la base de datos y el usuario indicados **ya existan** y las
  credenciales sean correctas

Si algo falla, el script se detiene ahí mismo con un mensaje claro de qué
corregir — no queda nada a medio instalar.

### Ejecución reanudable

Si el script se interrumpe o falla a mitad de la instalación (por ejemplo,
por un corte de red al descargar), simplemente corrígelo y vuelve a
ejecutar el mismo comando: el script recuerda qué pasos ya completó (en
`<INSTALL_DIR>/.install_state`) y no los repite — continúa justo donde se
quedó.

Al terminar, verás algo como:

```
============================================================================
 ¡Instalación completa!
============================================================================

 URL:       http://localhost/
 Usuario:   admin
 Password:  pointofsale   <-- CÁMBIALA en el primer login
```

## Después de instalar

1. **Cambia la contraseña de `admin`** de inmediato desde tu perfil dentro
   de la aplicación.
2. Ve a **Config → Localization** para ajustar país, idioma y moneda según
   tu ubicación.
3. Ve a **Config → Taxes** para configurar tus tasas de impuestos (IVA,
   u otro, según tu país — puedes dejarlas en 0% si no aplicas impuestos
   en tus productos).
4. Si vas a exponer el acceso remoto, se recomienda usar una VPN de malla
   como [Tailscale](https://tailscale.com/) en vez de abrir puertos
   directamente a internet.

## Variables de configuración del script

| Variable          | Default                  | Descripción                                      |
|-------------------|---------------------------|---------------------------------------------------|
| `OSPOS_VERSION`   | `3.4.1`                   | Tag de la release a instalar                       |
| `INSTALL_DIR`     | `/var/www/ospos`          | Carpeta destino de la instalación                  |
| `APACHE_SITE_NAME`| `ospos`                   | Nombre del archivo de VirtualHost                  |
| `DB_HOST`         | `localhost`               | Host de MariaDB                                    |
| `DB_NAME`         | `ospos`                   | Nombre de la base de datos (ya debe existir)       |
| `DB_USER`         | `ospos`                   | Usuario de MariaDB (ya debe existir)               |
| `DB_PASSWORD`     | *(se pide interactivamente)* | Contraseña del usuario de MariaDB              |
| `APP_BASE_URL`    | `http://localhost/`       | URL base de la app (usa tu IP local si aplica)     |
| `APP_TIMEZONE`    | `America/Mexico_City`     | Zona horaria de la aplicación                      |
| `SYSTEM_LOCALE`   | `es_MX.UTF-8`             | Locale del sistema a generar                       |

## Reportar bugs al proyecto oficial

Si quieres ayudar a que esto se arregle en el propio OSPOS y ya nadie tenga
que pasar por esto, considera abrir un Issue en
[opensourcepos/opensourcepos](https://github.com/opensourcepos/opensourcepos/issues)
señalando los puntos de `TROUBLESHOOTING.md` — especialmente el archivo
`Locale.php` faltante y la dependencia de `bcmath` no documentada como
requisito.

## Licencia

Este script se distribuye bajo licencia MIT (ver `LICENSE`). **OSPOS en sí
tiene su propia licencia** (GPLv3 en el momento de escribir esto) — revisa
el archivo `LICENSE` dentro del paquete oficial de OSPOS para los términos
que aplican al software en sí.

## Autor

**Clay Velázquez Rubio** ([@McClay429](https://github.com/McClay429))

## Roadmap (ideas futuras)

- [ ] Guía/script opcional para configurar acceso remoto vía Tailscale
      (sin exponer puertos a internet)
- [ ] Modo interactivo para preconfigurar país/moneda/impuestos durante
      la instalación
- [ ] Soporte para otras versiones de OSPOS además de 3.4.1
